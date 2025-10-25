# Listing 005

This listing continues the Rust-side value conversion, handling collections, ranges, sets, time, regexps, structs, OpenStructs,
and arbitrary objects before introducing `record_variables`, which captures locals from a binding. All snippets originate from
`gems/codetracer-ruby-recorder/ext/native_tracer/src/lib.rs`.

**Recognize a Ruby Array and prepare to iterate over its elements.**
```rust
    if RB_TYPE_P(val, rb_sys::ruby_value_type::RUBY_T_ARRAY) {
        let len = RARRAY_LEN(val) as usize;
        let mut elements = Vec::with_capacity(len);
        let ptr = RARRAY_CONST_PTR(val);
```

**Recursively convert each element and accumulate the results.**
```rust
        for i in 0..len {
            let elem = *ptr.add(i);
            elements.push(to_value(recorder, elem, depth - 1));
        }
```

**Register the Array type and return a sequence record.**
```rust
        let type_id = TraceWriter::ensure_type_id(&mut *recorder.tracer, TypeKind::Seq, "Array");
        return ValueRecord::Sequence {
            elements,
            is_slice: false,
            type_id,
        };
    }
```

**Convert a Ruby Hash by first turning it into an array of pairs.**
```rust
    if RB_TYPE_P(val, rb_sys::ruby_value_type::RUBY_T_HASH) {
        let pairs = rb_funcall(val, recorder.id.to_a, 0);
        let len = RARRAY_LEN(pairs) as usize;
        let ptr = RARRAY_CONST_PTR(pairs);
```

**For each pair, build a struct with `k` and `v` fields.**
```rust
        let mut elements = Vec::with_capacity(len);
        for i in 0..len {
            let pair = *ptr.add(i);
            if !RB_TYPE_P(pair, rb_sys::ruby_value_type::RUBY_T_ARRAY) || RARRAY_LEN(pair) < 2 {
                continue;
            }
            let pair_ptr = RARRAY_CONST_PTR(pair);
            let key = *pair_ptr.add(0);
            let val_elem = *pair_ptr.add(1);
            elements.push(struct_value(
                recorder,
                "Pair",
                &["k", "v"],
                &[key, val_elem],
                depth,
            ));
        }
```

**Return the Hash as a sequence of `Pair` structs.**
```rust
        let type_id = TraceWriter::ensure_type_id(&mut *recorder.tracer, TypeKind::Seq, "Hash");
        return ValueRecord::Sequence {
            elements,
            is_slice: false,
            type_id,
        };
    }
```

**Ranges serialize their `begin` and `end` values into a struct.**
```rust
    if rb_obj_is_kind_of(val, rb_cRange) != 0 {
        let begin_val = rb_funcall(val, recorder.id.begin, 0);
        let end_val = rb_funcall(val, recorder.id.end, 0);
        return struct_value(
            recorder,
            "Range",
            &["begin", "end"],
            &[begin_val, end_val],
            depth,
        );
    }
```

**Detect `Set` only once and serialize it as a sequence of members.**
```rust
    if NIL_P(recorder.set_class) {
        if rb_const_defined(rb_cObject, recorder.id.set_const) != 0 {
            recorder.set_class = rb_const_get(rb_cObject, recorder.id.set_const);
        }
    }
    if !NIL_P(recorder.set_class) && rb_obj_is_kind_of(val, recorder.set_class) != 0 {
        let arr = rb_funcall(val, recorder.id.to_a, 0);
        if RB_TYPE_P(arr, rb_sys::ruby_value_type::RUBY_T_ARRAY) {
            let len = RARRAY_LEN(arr) as usize;
            let ptr = RARRAY_CONST_PTR(arr);
            let mut elements = Vec::with_capacity(len);
            for i in 0..len {
                let elem = *ptr.add(i);
                elements.push(to_value(recorder, elem, depth - 1));
            }
            let type_id = TraceWriter::ensure_type_id(&mut *recorder.tracer, TypeKind::Seq, "Set");
            return ValueRecord::Sequence {
                elements,
                is_slice: false,
                type_id,
            };
        }
    }
```

**Time objects expose seconds and nanoseconds via helper methods.**
```rust
    if rb_obj_is_kind_of(val, rb_cTime) != 0 {
        let sec = rb_funcall(val, recorder.id.to_i, 0);
        let nsec = rb_funcall(val, recorder.id.nsec, 0);
        return struct_value(recorder, "Time", &["sec", "nsec"], &[sec, nsec], depth);
    }
```

**Regular expressions capture their source pattern and options.**
```rust
    if rb_obj_is_kind_of(val, rb_cRegexp) != 0 {
        let src = rb_funcall(val, recorder.id.source, 0);
        let opts = rb_funcall(val, recorder.id.options, 0);
        return struct_value(
            recorder,
            "Regexp",
            &["source", "options"],
            &[src, opts],
            depth,
        );
    }
```

**Structs are unpacked by member names and values; unknown layouts fall back to raw.**
```rust
    if rb_obj_is_kind_of(val, rb_cStruct) != 0 {
        let class_name =
            cstr_to_string(rb_obj_classname(val)).unwrap_or_else(|| "Struct".to_string());
        let members = rb_funcall(val, recorder.id.members, 0);
        let values = rb_funcall(val, recorder.id.values, 0);
        if !RB_TYPE_P(members, rb_sys::ruby_value_type::RUBY_T_ARRAY)
            || !RB_TYPE_P(values, rb_sys::ruby_value_type::RUBY_T_ARRAY)
        {
            let text = value_to_string(recorder, val);
            let type_id =
                TraceWriter::ensure_type_id(&mut *recorder.tracer, TypeKind::Raw, &class_name);
            return ValueRecord::Raw { r: text, type_id };
        }
```

**Collect each struct field's name and VALUE pointer before delegation to `struct_value`.**
```rust
        let len = RARRAY_LEN(values) as usize;
        let mem_ptr = RARRAY_CONST_PTR(members);
        let val_ptr = RARRAY_CONST_PTR(values);
        let mut names: Vec<&str> = Vec::with_capacity(len);
        let mut vals: Vec<VALUE> = Vec::with_capacity(len);
        for i in 0..len {
            let sym = *mem_ptr.add(i);
            let id = rb_sym2id(sym);
            let cstr = rb_id2name(id);
            let name = CStr::from_ptr(cstr).to_str().unwrap_or("?");
            names.push(name);
            vals.push(*val_ptr.add(i));
        }
        return struct_value(recorder, &class_name, &names, &vals, depth);
    }
```

**OpenStruct values are converted to hashes and reprocessed.**
```rust
    if NIL_P(recorder.open_struct_class) {
        if rb_const_defined(rb_cObject, recorder.id.open_struct_const) != 0 {
            recorder.open_struct_class = rb_const_get(rb_cObject, recorder.id.open_struct_const);
        }
    }
    if !NIL_P(recorder.open_struct_class) && rb_obj_is_kind_of(val, recorder.open_struct_class) != 0
    {
        let h = rb_funcall(val, recorder.id.to_h, 0);
        return to_value(recorder, h, depth - 1);
    }
```

**For generic objects, collect instance variables or fall back to a raw string.**
```rust
    let class_name = cstr_to_string(rb_obj_classname(val)).unwrap_or_else(|| "Object".to_string());
    // generic object
    let ivars = rb_funcall(val, recorder.id.instance_variables, 0);
    if !RB_TYPE_P(ivars, rb_sys::ruby_value_type::RUBY_T_ARRAY) {
        let text = value_to_string(recorder, val);
        let type_id =
            TraceWriter::ensure_type_id(&mut *recorder.tracer, TypeKind::Raw, &class_name);
        return ValueRecord::Raw { r: text, type_id };
    }
```

**Map each instance variable name to its value and emit a struct if any exist.**
```rust
    let len = RARRAY_LEN(ivars) as usize;
    let ptr = RARRAY_CONST_PTR(ivars);
    let mut names: Vec<&str> = Vec::with_capacity(len);
    let mut vals: Vec<VALUE> = Vec::with_capacity(len);
    for i in 0..len {
        let sym = *ptr.add(i);
        let id = rb_sym2id(sym);
        let cstr = rb_id2name(id);
        let name = CStr::from_ptr(cstr).to_str().unwrap_or("?");
        names.push(name);
        let value = rb_funcall(val, recorder.id.instance_variable_get, 1, sym);
        vals.push(value);
    }
    if !names.is_empty() {
        return struct_value(recorder, &class_name, &names, &vals, depth);
    }
    let text = value_to_string(recorder, val);
    let type_id = TraceWriter::ensure_type_id(&mut *recorder.tracer, TypeKind::Raw, &class_name);
    ValueRecord::Raw { r: text, type_id }
}
```

**`record_variables` pulls local variable names from a binding.**
```rust
unsafe fn record_variables(recorder: &mut Recorder, binding: VALUE) -> Vec<FullValueRecord> {
    let vars = rb_funcall(binding, recorder.id.local_variables, 0);
    if !RB_TYPE_P(vars, rb_sys::ruby_value_type::RUBY_T_ARRAY) {
        return Vec::new();
    }
```

**Iterate over each variable, converting and registering its value.**
```rust
    let len = RARRAY_LEN(vars) as usize;
    let mut result = Vec::with_capacity(len);
    let ptr = RARRAY_CONST_PTR(vars);
    for i in 0..len {
        let sym = *ptr.add(i);
        let id = rb_sym2id(sym);
        let name = CStr::from_ptr(rb_id2name(id)).to_str().unwrap_or("");
        let value = rb_funcall(binding, recorder.id.local_variable_get, 1, sym);
        let val_rec = to_value(recorder, value, 10);
        TraceWriter::register_variable_with_full_value(
            &mut *recorder.tracer,
            name,
            val_rec.clone(),
        );
        let var_id = TraceWriter::ensure_variable_id(&mut *recorder.tracer, name);
        result.push(FullValueRecord {
            variable_id: var_id,
            value: val_rec,
        });
    }
    result
}
```
