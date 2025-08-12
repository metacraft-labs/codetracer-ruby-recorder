# Listing 004

This section unpacks how the Rust extension manages the recorder’s lifecycle and begins translating Ruby objects into traceable Rust structures. We examine `gems/codetracer-ruby-recorder/ext/native_tracer/src/lib.rs` around the helper for struct serialization, the FFI hooks that allocate and enable the recorder, and the start of `to_value` which handles primitive Ruby types.

**Serialize a Ruby struct into a typed runtime-tracing record, computing field type IDs and assigning a versioned name.**
```rust
unsafe fn struct_value(
    recorder: &mut Recorder,
    class_name: &str,
    field_names: &[&str],
    field_values: &[VALUE],
    depth: usize,
) -> ValueRecord {
    let mut vals = Vec::with_capacity(field_values.len());
    for &v in field_values {
        vals.push(to_value(recorder, v, depth - 1));
    }

    let version_entry = recorder
        .struct_type_versions
        .entry(class_name.to_string())
        .or_insert(0);
    let name_version = format!("{} (#{})", class_name, *version_entry);
    *version_entry += 1;
    let mut field_types = Vec::with_capacity(field_names.len());
    for (n, v) in field_names.iter().zip(&vals) {
        field_types.push(FieldTypeRecord {
            name: (*n).to_string(),
            type_id: value_type_id(v),
        });
    }
    let typ = TypeRecord {
        kind: TypeKind::Struct,
        lang_type: name_version,
        specific_info: TypeSpecificInfo::Struct {
            fields: field_types,
        },
    };
    let type_id = TraceWriter::ensure_raw_type_id(&mut *recorder.tracer, typ);

    ValueRecord::Struct {
        field_values: vals,
        type_id,
    }
}
```

**Custom destructor frees the Rust `Recorder` when Ruby’s GC releases the wrapper object.**
```rust
unsafe extern "C" fn recorder_free(ptr: *mut c_void) {
    if !ptr.is_null() {
        drop(Box::from_raw(ptr as *mut Recorder));
    }
}
```

**Declare Ruby’s view of the `Recorder` data type, wiring in the free callback for GC.**
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

**Fetch the internal `Recorder` pointer from a Ruby object, raising `IOError` if the type does not match.**
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

**Allocator for the Ruby class instantiates a boxed `Recorder` with default type IDs and inactive state.**
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

**Enable tracing by registering a low-level event hook; only one hook is active at a time.**
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

**Disable tracing by removing the previously installed event hook.**
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

**Helper that converts a C string pointer to a Rust `String`, returning `None` if null.**
```rust
unsafe fn cstr_to_string(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    CStr::from_ptr(ptr).to_str().ok().map(|s| s.to_string())
}
```

**Extract a UTF‑8 string from a Ruby `VALUE`, replacing invalid bytes.**
```rust
unsafe fn rstring_lossy(val: VALUE) -> String {
    let ptr = RSTRING_PTR(val);
    let len = RSTRING_LEN(val) as usize;
    let slice = std::slice::from_raw_parts(ptr as *const u8, len);
    String::from_utf8_lossy(slice).to_string()
}
```

**Beginning of `to_value`: limit depth, map `nil` and booleans, and convert integers and floats with cached type IDs.**
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
    if val == (Qtrue as VALUE) || val == (Qfalse as VALUE) {
        return ValueRecord::Bool {
            b: val == (Qtrue as VALUE),
            type_id: recorder.bool_type_id,
        };
    }
    if RB_INTEGER_TYPE_P(val) {
        let i = rb_num2long(val) as i64;
        return ValueRecord::Int {
            i,
            type_id: recorder.int_type_id,
        };
    }
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
    if RB_SYMBOL_P(val) {
        return ValueRecord::String {
            text: cstr_to_string(rb_id2name(rb_sym2id(val))).unwrap_or_default(),
            type_id: recorder.symbol_type_id,
        };
    }
    if RB_TYPE_P(val, rb_sys::ruby_value_type::RUBY_T_STRING) {
        return ValueRecord::String {
            text: rstring_lossy(val),
            type_id: recorder.string_type_id,
        };
    }
```
