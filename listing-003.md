# Listing 003

This listing examines the build pipeline and initial Rust implementation of the native tracer. We review the `extconf.rb` script, `build.rs`, the crate's `Cargo.toml`, and the opening portions of `src/lib.rs` that set up symbol lookups, recorder state, and early helper functions.

**Invoke mkmf and rb_sys to generate a Makefile for the Rust extension.**
```ruby
require 'mkmf'
require 'rb_sys/mkmf'

create_rust_makefile('codetracer_ruby_recorder')
```

**Activate rb_sys environment variables during Cargo build.**
```rust
fn main() -> Result<(), Box<dyn std::error::Error>> {
    rb_sys_env::activate()?;
    Ok(())
}
```

**Define package metadata, library type, dependencies, and build helpers.**
```toml
[package]
name = "codetracer_ruby_recorder"
description = "Native Ruby module for generating CodeTracer trace files"
version = "0.1.0"
edition = "2021"
build = "build.rs"

[lib]
crate-type = ["cdylib"]

[dependencies]
rb-sys = "0.9"
runtime_tracing = "0.14.0"

[build-dependencies]
rb-sys-env = "0.2"

[profile.release]
codegen-units = 1
lto = "thin"
opt-level = 3
```

**Allow missing safety docs and import standard, Ruby, and tracing crates.**
```rust
#![allow(clippy::missing_safety_doc)]

use std::{
    collections::HashMap,
    ffi::CStr,
    mem::transmute,
    os::raw::{c_char, c_int, c_void},
    path::Path,
    ptr,
};

use rb_sys::{
    rb_cObject, rb_define_alloc_func, rb_define_class, rb_define_method, rb_eIOError,
    rb_event_flag_t, rb_funcall, rb_id2name, rb_id2sym, rb_intern, rb_num2long, rb_obj_classname,
    rb_raise, rb_sym2id, ID, RUBY_EVENT_CALL, RUBY_EVENT_LINE, RUBY_EVENT_RAISE, RUBY_EVENT_RETURN,
    VALUE,
};
use rb_sys::{
    rb_protect, NIL_P, RARRAY_CONST_PTR, RARRAY_LEN, RB_FLOAT_TYPE_P, RB_INTEGER_TYPE_P,
    RB_SYMBOL_P, RB_TYPE_P, RSTRING_LEN, RSTRING_PTR,
};
use rb_sys::{Qfalse, Qnil, Qtrue};
use runtime_tracing::{
    create_trace_writer, CallRecord, EventLogKind, FieldTypeRecord, FullValueRecord, Line,
    TraceEventsFileFormat, TraceLowLevelEvent, TraceWriter, TypeKind, TypeRecord, TypeSpecificInfo,
    ValueRecord,
};
```

**Declare event hook type and import flag enum and additional binding functions.**
```rust
// Event hook function type from Ruby debug.h
type rb_event_hook_func_t = Option<unsafe extern "C" fn(rb_event_flag_t, VALUE, VALUE, ID, VALUE)>;

// Use event hook flags enum from rb_sys
use rb_sys::rb_event_hook_flag_t;

// Types from rb_sys bindings
use rb_sys::{
    rb_add_event_hook2, rb_cRange, rb_cRegexp, rb_cStruct, rb_cTime, rb_check_typeddata,
    rb_const_defined, rb_const_get, rb_data_type_struct__bindgen_ty_1, rb_data_type_t,
    rb_data_typed_object_wrap, rb_method_boundp, rb_num2dbl, rb_obj_is_kind_of,
    rb_remove_event_hook_with_data, rb_trace_arg_t, rb_tracearg_binding, rb_tracearg_callee_id,
    rb_tracearg_event_flag, rb_tracearg_lineno, rb_tracearg_path, rb_tracearg_raised_exception,
    rb_tracearg_return_value, rb_tracearg_self,
};
```

**Collect frequently used Ruby method identifiers for efficient lookup.**
```rust
struct InternedSymbols {
    to_s: ID,
    local_variables: ID,
    local_variable_get: ID,
    instance_method: ID,
    parameters: ID,
    class: ID,
    to_a: ID,
    begin: ID,
    end: ID,
    to_i: ID,
    nsec: ID,
    source: ID,
    options: ID,
    members: ID,
    values: ID,
    to_h: ID,
    instance_variables: ID,
    instance_variable_get: ID,
    set_const: ID,
    open_struct_const: ID,
}
```

**Construct the symbol table by interning method names.**
```rust
impl InternedSymbols {
    unsafe fn new() -> InternedSymbols {
        InternedSymbols {
            to_s: rb_intern!("to_s"),
            local_variables: rb_intern!("local_variables"),
            local_variable_get: rb_intern!("local_variable_get"),
            instance_method: rb_intern!("instance_method"),
            parameters: rb_intern!("parameters"),
            class: rb_intern!("class"),
            to_a: rb_intern!("to_a"),
            begin: rb_intern!("begin"),
            end: rb_intern!("end"),
            to_i: rb_intern!("to_i"),
            nsec: rb_intern!("nsec"),
            source: rb_intern!("source"),
            options: rb_intern!("options"),
            members: rb_intern!("members"),
            values: rb_intern!("values"),
            to_h: rb_intern!("to_h"),
            instance_variables: rb_intern!("instance_variables"),
            instance_variable_get: rb_intern!("instance_variable_get"),
            set_const: rb_intern!("Set"),
            open_struct_const: rb_intern!("OpenStruct"),
        }
    }
}
```

**Define the recorder state with tracing backend, flags, and cached type IDs.**
```rust
struct Recorder {
    tracer: Box<dyn TraceWriter>,
    active: bool,
    id: InternedSymbols,
    set_class: VALUE,
    open_struct_class: VALUE,
    struct_type_versions: HashMap<String, usize>,
    int_type_id: runtime_tracing::TypeId,
    float_type_id: runtime_tracing::TypeId,
    bool_type_id: runtime_tracing::TypeId,
    string_type_id: runtime_tracing::TypeId,
    symbol_type_id: runtime_tracing::TypeId,
    error_type_id: runtime_tracing::TypeId,
}
```

**Skip instrumentation for internal or library paths to reduce noise.**
```rust
fn should_ignore_path(path: &str) -> bool {
    const PATTERNS: [&str; 5] = [
        "codetracer_ruby_recorder.rb",
        "lib/ruby",
        "recorder.rb",
        "codetracer_pure_ruby_recorder.rb",
        "gems/",
    ];
    if path.starts_with("<internal:") {
        return true;
    }
    PATTERNS.iter().any(|p| path.contains(p))
}
```

**Retrieve the type ID embedded within a `ValueRecord` variant.**
```rust
fn value_type_id(val: &ValueRecord) -> runtime_tracing::TypeId {
    use ValueRecord::*;
    match val {
        Int { type_id, .. }
        | Float { type_id, .. }
        | Bool { type_id, .. }
        | String { type_id, .. }
        | Sequence { type_id, .. }
        | Tuple { type_id, .. }
        | Struct { type_id, .. }
        | Variant { type_id, .. }
        | Reference { type_id, .. }
        | Raw { type_id, .. }
        | Error { type_id, .. }
        | BigInt { type_id, .. }
        | None { type_id } => *type_id,
        Cell { .. } => runtime_tracing::NONE_TYPE_ID,
    }
}
```
