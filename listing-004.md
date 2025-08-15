# Listing 004

This listing follows the Rust half of the recorder, showing how the extension allocates and frees the `Recorder`, toggles Ruby's trace hooks, and begins translating primitive Ruby values. All snippets come from `gems/codetracer-ruby-recorder/ext/native_tracer/src/lib.rs`.

**Signature for `struct_value` collects the recorder context, struct metadata, and a recursion depth.**
```rust
unsafe fn struct_value(
    recorder: &mut Recorder,
    class_name: &str,
    field_names: &[&str],
    field_values: &[VALUE],
    depth: usize,
) -> ValueRecord {
```

**Allocate space for converted fields and recursively map each Ruby field to a `ValueRecord`.**
```rust
    let mut vals = Vec::with_capacity(field_values.len());
    for &v in field_values {
        vals.push(to_value(recorder, v, depth - 1));
    }
```

**Track a monotonically increasing version number per struct name.**
```rust
    let version_entry = recorder
        .struct_type_versions
        .entry(class_name.to_string())
        .or_insert(0);
    let name_version = format!("{} (#{})", class_name, *version_entry);
    *version_entry += 1;
```

**Describe each field by name and the type ID of its converted value.**
```rust
    let mut field_types = Vec::with_capacity(field_names.len());
    for (n, v) in field_names.iter().zip(&vals) {
        field_types.push(FieldTypeRecord {
            name: (*n).to_string(),
            type_id: value_type_id(v),
        });
    }
```

**Assemble a `TypeRecord` for the struct and register it with the trace writer to obtain a type ID.**
```rust
    let typ = TypeRecord {
        kind: TypeKind::Struct,
        lang_type: name_version,
        specific_info: TypeSpecificInfo::Struct {
            fields: field_types,
        },
    };
    let type_id = TraceWriter::ensure_raw_type_id(&mut *recorder.tracer, typ);
```

**Return a structured value with its field data and associated type ID.**
```rust
    ValueRecord::Struct {
        field_values: vals,
        type_id,
    }
}
```

**`recorder_free` is registered as a destructor and drops the boxed recorder when the Ruby object is garbage collected.**
```rust
unsafe extern "C" fn recorder_free(ptr: *mut c_void) {
    if !ptr.is_null() {
        drop(Box::from_raw(ptr as *mut Recorder));
    }
}
```

**`RECORDER_TYPE` exposes the recorder to Ruby, naming the type and specifying the `dfree` callback.**
```rust
static mut RECORDER_TYPE: rb_data_type_t = rb_data_type_t {
    wrap_struct_name: b"Recorder\0".as_ptr() as *const c_char,
    function: rb_data_type_struct__bindgen_ty_1 {
        dmark: None,
        dfree: Some(recorder_free),
        dsize: None,
        dcompact: None,
        reserved: [ptr::null_mut(); 1],
    },
    parent: ptr::null(),
    data: ptr::null_mut(),
    flags: 0 as VALUE,
};
```

**`get_recorder` fetches the internal pointer from a Ruby object, raising `IOError` if the type check fails.**
```rust
unsafe fn get_recorder(obj: VALUE) -> *mut Recorder {
    let ty = std::ptr::addr_of!(RECORDER_TYPE) as *const rb_data_type_t;
    let ptr = rb_check_typeddata(obj, ty);
    if ptr.is_null() {
        rb_raise(
            rb_eIOError,
            b"Invalid recorder object\0".as_ptr() as *const c_char,
        );
    }
    ptr as *mut Recorder
}
```

**Allocator for the Ruby class constructs a fresh `Recorder` with default type IDs and inactive tracing.**
```rust
unsafe extern "C" fn ruby_recorder_alloc(klass: VALUE) -> VALUE {
    let recorder = Box::new(Recorder {
        tracer: create_trace_writer("ruby", &vec![], TraceEventsFileFormat::Binary),
        active: false,
        id: InternedSymbols::new(),
        set_class: Qnil.into(),
        open_struct_class: Qnil.into(),
        struct_type_versions: HashMap::new(),
        int_type_id: runtime_tracing::TypeId::default(),
        float_type_id: runtime_tracing::TypeId::default(),
        bool_type_id: runtime_tracing::TypeId::default(),
        string_type_id: runtime_tracing::TypeId::default(),
        symbol_type_id: runtime_tracing::TypeId::default(),
        error_type_id: runtime_tracing::TypeId::default(),
    });
    let ty = std::ptr::addr_of!(RECORDER_TYPE) as *const rb_data_type_t;
    rb_data_typed_object_wrap(klass, Box::into_raw(recorder) as *mut c_void, ty)
}
```

**`enable_tracing` attaches a raw event hook so Ruby invokes our callback on line, call, return, and raise events.**
```rust
unsafe extern "C" fn enable_tracing(self_val: VALUE) -> VALUE {
    let recorder = &mut *get_recorder(self_val);
    if !recorder.active {
        let raw_cb: unsafe extern "C" fn(VALUE, *mut rb_trace_arg_t) = event_hook_raw;
        let func: rb_event_hook_func_t = Some(transmute(raw_cb));
        rb_add_event_hook2(
            func,
            RUBY_EVENT_LINE | RUBY_EVENT_CALL | RUBY_EVENT_RETURN | RUBY_EVENT_RAISE,
            self_val,
            rb_event_hook_flag_t::RUBY_EVENT_HOOK_FLAG_RAW_ARG,
        );
        recorder.active = true;
    }
    Qnil.into()
}
```

**`disable_tracing` removes that hook and marks the recorder inactive.**
```rust
unsafe extern "C" fn disable_tracing(self_val: VALUE) -> VALUE {
    let recorder = &mut *get_recorder(self_val);
    if recorder.active {
        let raw_cb: unsafe extern "C" fn(VALUE, *mut rb_trace_arg_t) = event_hook_raw;
        let func: rb_event_hook_func_t = Some(transmute(raw_cb));
        rb_remove_event_hook_with_data(func, self_val);
        recorder.active = false;
    }
    Qnil.into()
}
```

**`cstr_to_string` converts a C string pointer to a Rust `String`, returning `None` when the pointer is null.**
```rust
unsafe fn cstr_to_string(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    CStr::from_ptr(ptr).to_str().ok().map(|s| s.to_string())
}
```

**`rstring_lossy` reads a Ruby `String`'s raw bytes and builds a UTF‑8 string, replacing invalid sequences.**
```rust
unsafe fn rstring_lossy(val: VALUE) -> String {
    let ptr = RSTRING_PTR(val);
    let len = RSTRING_LEN(val) as usize;
    let slice = std::slice::from_raw_parts(ptr as *const u8, len);
    String::from_utf8_lossy(slice).to_string()
}
```

**`to_value` begins value translation, first enforcing a recursion limit and checking for `nil`.**
```rust
unsafe fn to_value(recorder: &mut Recorder, val: VALUE, depth: usize) -> ValueRecord {
    if depth == 0 {
        return ValueRecord::None {
            type_id: recorder.error_type_id,
        };
    }
    if NIL_P(val) {
        return ValueRecord::None {
            type_id: recorder.error_type_id,
        };
    }
```

**Booleans map to `Bool` records, distinguishing `true` from `false` and reusing a cached type ID.**
```rust
    if val == (Qtrue as VALUE) || val == (Qfalse as VALUE) {
        return ValueRecord::Bool {
            b: val == (Qtrue as VALUE),
            type_id: recorder.bool_type_id,
        };
    }
```

**Integers become `Int` records holding the numeric value and its type ID.**
```rust
    if RB_INTEGER_TYPE_P(val) {
        let i = rb_num2long(val) as i64;
        return ValueRecord::Int {
            i,
            type_id: recorder.int_type_id,
        };
    }
```

**For floats, lazily register the `Float` type and then store the numeric value with the obtained ID.**
```rust
    if RB_FLOAT_TYPE_P(val) {
        let f = rb_num2dbl(val);
        let type_id = if recorder.float_type_id == runtime_tracing::NONE_TYPE_ID {
            let id = TraceWriter::ensure_type_id(&mut *recorder.tracer, TypeKind::Float, "Float");
            recorder.float_type_id = id;
            id
        } else {
            recorder.float_type_id
        };
        return ValueRecord::Float { f, type_id };
    }
```

**Symbols are encoded as strings using their interned names and the cached symbol type ID.**
```rust
    if RB_SYMBOL_P(val) {
        return ValueRecord::String {
            text: cstr_to_string(rb_id2name(rb_sym2id(val))).unwrap_or_default(),
            type_id: recorder.symbol_type_id,
        };
    }
```

**Finally, Ruby `String` objects are copied lossily into UTF‑8 and tagged with the string type ID.**
```rust
    if RB_TYPE_P(val, rb_sys::ruby_value_type::RUBY_T_STRING) {
        return ValueRecord::String {
            text: rstring_lossy(val),
            type_id: recorder.string_type_id,
        };
    }
}
```
