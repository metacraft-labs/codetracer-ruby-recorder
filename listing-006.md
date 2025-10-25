# Listing 006

This listing continues in `gems/codetracer-ruby-recorder/ext/native_tracer/src/lib.rs`, covering helper routines that extract method parameters, register them with the tracer, and expose C-callable APIs for initialization, flushing, and emitting custom events.

**Prepare to collect parameters by defining the function signature and required arguments.**
```rust
unsafe fn collect_parameter_values(
    recorder: &mut Recorder,
    binding: VALUE,
    defined_class: VALUE,
    mid: ID,
) -> Vec<(String, ValueRecord)> {
```

**Convert the method ID to a Ruby symbol and bail out if the method isn't found.**
```rust
    let method_sym = rb_id2sym(mid);
    if rb_method_boundp(defined_class, mid, 0) == 0 {
        return Vec::new();
    }
```

**Fetch the `Method` object and query its parameter metadata, ensuring an array is returned.**
```rust
    let method_obj = rb_funcall(defined_class, recorder.id.instance_method, 1, method_sym);
    let params_ary = rb_funcall(method_obj, recorder.id.parameters, 0);
    if !RB_TYPE_P(params_ary, rb_sys::ruby_value_type::RUBY_T_ARRAY) {
        return Vec::new();
    }
```

**Determine how many parameters exist and prime a results vector of matching capacity.**
```rust
    let params_len = RARRAY_LEN(params_ary) as usize;
    let params_ptr = RARRAY_CONST_PTR(params_ary);
    let mut result = Vec::with_capacity(params_len);
```

**Iterate through each parameter description, skipping malformed entries.**
```rust
    for i in 0..params_len {
        let pair = *params_ptr.add(i);
        if !RB_TYPE_P(pair, rb_sys::ruby_value_type::RUBY_T_ARRAY) || RARRAY_LEN(pair) < 2 {
            continue;
        }
        let pair_ptr = RARRAY_CONST_PTR(pair);
```

**Extract the parameter's name symbol, ignoring `nil` placeholders.**
```rust
        let name_sym = *pair_ptr.add(1);
        if NIL_P(name_sym) {
            continue;
        }
```

**Convert the symbol to a C string; if conversion fails, skip the parameter.**
```rust
        let name_id = rb_sym2id(name_sym);
        let name_c = rb_id2name(name_id);
        if name_c.is_null() {
            continue;
        }
        let name = CStr::from_ptr(name_c).to_str().unwrap_or("").to_string();
```

**Read the argument's value from the binding and turn it into a `ValueRecord`.**
```rust
        let value = rb_funcall(binding, recorder.id.local_variable_get, 1, name_sym);
        let val_rec = to_value(recorder, value, 10);
        result.push((name, val_rec));
    }
    result
}
```

**Define `register_parameter_values` to persist parameters and their values with the tracer.**
```rust
unsafe fn register_parameter_values(
    recorder: &mut Recorder,
    params: Vec<(String, ValueRecord)>,
) -> Vec<FullValueRecord> {
```

**Allocate space for the returned records and walk through each `(name, value)` pair.**
```rust
    let mut result = Vec::with_capacity(params.len());
    for (name, val_rec) in params {
```

**Record the variable and ensure it has a stable ID in the trace.**
```rust
        TraceWriter::register_variable_with_full_value(
            &mut *recorder.tracer,
            &name,
            val_rec.clone(),
        );
        let var_id = TraceWriter::ensure_variable_id(&mut *recorder.tracer, &name);
```

**Store the final `FullValueRecord` in the results vector and finish.**
```rust
        result.push(FullValueRecord {
            variable_id: var_id,
            value: val_rec,
        });
    }
    result
}
```

**`record_event` logs an arbitrary string event at a given file path and line.**
```rust
unsafe fn record_event(tracer: &mut dyn TraceWriter, path: &str, line: i64, content: String) {
    TraceWriter::register_step(tracer, Path::new(path), Line(line));
    TraceWriter::register_special_event(tracer, EventLogKind::Write, &content)
}
```

**Begin the C-facing `initialize` function, pulling pointers from Ruby strings.**
```rust
unsafe extern "C" fn initialize(self_val: VALUE, out_dir: VALUE, format: VALUE) -> VALUE {
    let recorder_ptr = get_recorder(self_val);
    let recorder = &mut *recorder_ptr;
    let ptr = RSTRING_PTR(out_dir) as *const u8;
    let len = RSTRING_LEN(out_dir) as usize;
    let slice = std::slice::from_raw_parts(ptr, len);
```

**Determine the output file format, defaulting to JSON when no symbol is supplied.**
```rust
    let fmt = if !NIL_P(format) && RB_SYMBOL_P(format) {
        let id = rb_sym2id(format);
        match CStr::from_ptr(rb_id2name(id)).to_str().unwrap_or("") {
            "binaryv0" => runtime_tracing::TraceEventsFileFormat::BinaryV0,
            "binary" | "bin" => runtime_tracing::TraceEventsFileFormat::Binary,
            "json" => runtime_tracing::TraceEventsFileFormat::Json,
            _ => rb_raise(rb_eIOError, b"Unknown format\0".as_ptr() as *const c_char),
        }
    } else {
        runtime_tracing::TraceEventsFileFormat::Json
    };
```

**Attempt to start tracing, pre-registering common Ruby types on success.**
```rust
    match std::str::from_utf8(slice) {
        Ok(path_str) => {
            match begin_trace(Path::new(path_str), fmt) {
                Ok(t) => {
                    recorder.tracer = t;
                    // pre-register common types to match the pure Ruby tracer
                    recorder.int_type_id = TraceWriter::ensure_type_id(
                        &mut *recorder.tracer,
                        TypeKind::Int,
                        "Integer",
                    );
                    recorder.string_type_id = TraceWriter::ensure_type_id(
                        &mut *recorder.tracer,
                        TypeKind::String,
                        "String",
                    );
                    recorder.bool_type_id =
                        TraceWriter::ensure_type_id(&mut *recorder.tracer, TypeKind::Bool, "Bool");
                    recorder.float_type_id = runtime_tracing::NONE_TYPE_ID;
                    recorder.symbol_type_id = TraceWriter::ensure_type_id(
                        &mut *recorder.tracer,
                        TypeKind::String,
                        "Symbol",
                    );
                    recorder.error_type_id = TraceWriter::ensure_type_id(
                        &mut *recorder.tracer,
                        TypeKind::Error,
                        "No type",
                    );
                    let path = Path::new("");
                    let func_id = TraceWriter::ensure_function_id(
                        &mut *recorder.tracer,
                        "<top-level>",
                        path,
                        Line(1),
                    );
                    TraceWriter::add_event(
                        &mut *recorder.tracer,
                        TraceLowLevelEvent::Call(CallRecord {
                            function_id: func_id,
                            args: vec![],
                        }),
                    );
                }
                Err(e) => {
                    let msg = std::ffi::CString::new(e.to_string())
                        .unwrap_or_else(|_| std::ffi::CString::new("unknown error").unwrap());
                    rb_raise(
                        rb_eIOError,
                        b"Failed to flush trace: %s\0".as_ptr() as *const c_char,
                        msg.as_ptr(),
                    );
                }
            }
        }
        Err(e) => {
            let msg = std::ffi::CString::new(e.to_string())
                .unwrap_or_else(|_| std::ffi::CString::new("invalid utf8").unwrap());
            rb_raise(
                rb_eIOError,
                b"Invalid UTF-8 in path: %s\0".as_ptr() as *const c_char,
                msg.as_ptr(),
            )
        }
    }
```

**Finalize initialization by returning Ruby `nil`.**
```rust
    Qnil.into()
}
```

**Expose a `flush_trace` function for Ruby to write pending events to disk.**
```rust
unsafe extern "C" fn flush_trace(self_val: VALUE) -> VALUE {
    let recorder_ptr = get_recorder(self_val);
    let recorder = &mut *recorder_ptr;
```

**Attempt the flush and surface I/O errors back to Ruby.**
```rust
    if let Err(e) = flush_to_dir(&mut *recorder.tracer) {
        let msg = std::ffi::CString::new(e.to_string())
            .unwrap_or_else(|_| std::ffi::CString::new("unknown error").unwrap());
        rb_raise(
            rb_eIOError,
            b"Failed to flush trace: %s\0".as_ptr() as *const c_char,
            msg.as_ptr(),
        );
    }
```

**Return `nil` to signal success.**
```rust
    Qnil.into()
}
```

**`record_event_api` lets Ruby code log custom events with a path and line number.**
```rust
unsafe extern "C" fn record_event_api(
    self_val: VALUE,
    path: VALUE,
    line: VALUE,
    content: VALUE,
) -> VALUE {
```

**Retrieve the recorder and decode the optional path string from Ruby.**
```rust
    let recorder = &mut *get_recorder(self_val);
    let path_slice = if NIL_P(path) {
        ""
    } else {
        let ptr = RSTRING_PTR(path);
        let len = RSTRING_LEN(path) as usize;
        std::str::from_utf8(std::slice::from_raw_parts(ptr as *const u8, len)).unwrap_or("")
    };
```

**Convert the line number and content, then dispatch the event.**
```rust
    let line_num = rb_num2long(line) as i64;
    let content_str = value_to_string(recorder, content);
    record_event(&mut *recorder.tracer, path_slice, line_num, content_str);
    Qnil.into()
}
```
