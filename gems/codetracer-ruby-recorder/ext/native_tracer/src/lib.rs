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
    rb_add_event_hook2, rb_cObject, rb_cRange, rb_cRegexp, rb_cStruct, rb_cTime,
    rb_check_typeddata, rb_const_defined, rb_const_get, rb_data_type_struct__bindgen_ty_1,
    rb_data_type_t, rb_data_typed_object_wrap, rb_define_alloc_func, rb_define_class,
    rb_define_method, rb_eIOError, rb_event_flag_t, rb_event_hook_flag_t, rb_funcall, rb_id2name,
    rb_id2sym, rb_intern, rb_method_boundp, rb_num2dbl, rb_num2long, rb_obj_classname,
    rb_obj_is_kind_of, rb_protect, rb_raise, rb_remove_event_hook_with_data, rb_sym2id,
    rb_trace_arg_t, rb_tracearg_binding, rb_tracearg_callee_id, rb_tracearg_event_flag,
    rb_tracearg_lineno, rb_tracearg_path, rb_tracearg_raised_exception, rb_tracearg_return_value,
    rb_tracearg_self, Qfalse, Qnil, Qtrue, ID, NIL_P, RARRAY_CONST_PTR, RARRAY_LEN,
    RB_FLOAT_TYPE_P, RB_INTEGER_TYPE_P, RB_SYMBOL_P, RB_TYPE_P, RSTRING_LEN, RSTRING_PTR,
    RUBY_EVENT_CALL, RUBY_EVENT_LINE, RUBY_EVENT_RAISE, RUBY_EVENT_RETURN, VALUE,
};
use runtime_tracing::{
    create_trace_writer, CallRecord, EventLogKind, FieldTypeRecord, FullValueRecord, Line,
    TraceEventsFileFormat, TraceLowLevelEvent, TraceWriter, TypeKind, TypeRecord, TypeSpecificInfo,
    ValueRecord,
};

// Event hook function type from Ruby debug.h
type rb_event_hook_func_t = Option<unsafe extern "C" fn(rb_event_flag_t, VALUE, VALUE, ID, VALUE)>;

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

unsafe extern "C" fn recorder_free(ptr: *mut c_void) {
    if !ptr.is_null() {
        drop(Box::from_raw(ptr as *mut Recorder));
    }
}

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

fn begin_trace(
    dir: &Path,
    format: runtime_tracing::TraceEventsFileFormat,
) -> Result<Box<dyn TraceWriter>, Box<dyn std::error::Error>> {
    let mut tracer = create_trace_writer("ruby", &vec![], format);
    std::fs::create_dir_all(dir)?;
    let events = match format {
        runtime_tracing::TraceEventsFileFormat::Json => dir.join("trace.json"),
        runtime_tracing::TraceEventsFileFormat::BinaryV0
        | runtime_tracing::TraceEventsFileFormat::Binary => dir.join("trace.bin"),
    };
    let metadata = dir.join("trace_metadata.json");
    let paths = dir.join("trace_paths.json");

    TraceWriter::begin_writing_trace_events(&mut *tracer, &events)?;
    TraceWriter::begin_writing_trace_metadata(&mut *tracer, &metadata)?;
    TraceWriter::begin_writing_trace_paths(&mut *tracer, &paths)?;

    Ok(tracer)
}

fn flush_to_dir(tracer: &mut dyn TraceWriter) -> Result<(), Box<dyn std::error::Error>> {
    TraceWriter::finish_writing_trace_events(tracer)?;
    TraceWriter::finish_writing_trace_metadata(tracer)?;
    TraceWriter::finish_writing_trace_paths(tracer)?;
    Ok(())
}

unsafe fn cstr_to_string(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    CStr::from_ptr(ptr).to_str().ok().map(|s| s.to_string())
}

unsafe fn rstring_lossy(val: VALUE) -> String {
    let ptr = RSTRING_PTR(val);
    let len = RSTRING_LEN(val) as usize;
    let slice = std::slice::from_raw_parts(ptr as *const u8, len);
    String::from_utf8_lossy(slice).to_string()
}

unsafe fn value_to_string(recorder: &Recorder, val: VALUE) -> String {
    if RB_TYPE_P(val, rb_sys::ruby_value_type::RUBY_T_STRING) {
        rstring_lossy(val)
    } else {
        rstring_lossy(rb_funcall(val, recorder.id.to_s, 0))
    }
}

unsafe extern "C" fn call_to_s(arg: VALUE) -> VALUE {
    let data = &*(arg as *const (VALUE, ID));
    rb_funcall(data.0, data.1, 0)
}

unsafe fn value_to_string_safe(recorder: &Recorder, val: VALUE) -> String {
    if RB_TYPE_P(val, rb_sys::ruby_value_type::RUBY_T_STRING) {
        rstring_lossy(val)
    } else {
        let mut state: c_int = 0;
        let data = (val, recorder.id.to_s);
        let str_val = rb_protect(Some(call_to_s), &data as *const _ as VALUE, &mut state);
        if state != 0 {
            String::default()
        } else {
            rstring_lossy(str_val)
        }
    }
}

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
    if RB_TYPE_P(val, rb_sys::ruby_value_type::RUBY_T_ARRAY) {
        let len = RARRAY_LEN(val) as usize;
        let mut elements = Vec::with_capacity(len);
        let ptr = RARRAY_CONST_PTR(val);
        for i in 0..len {
            let elem = *ptr.add(i);
            elements.push(to_value(recorder, elem, depth - 1));
        }
        let type_id = TraceWriter::ensure_type_id(&mut *recorder.tracer, TypeKind::Seq, "Array");
        return ValueRecord::Sequence {
            elements,
            is_slice: false,
            type_id,
        };
    }
    if RB_TYPE_P(val, rb_sys::ruby_value_type::RUBY_T_HASH) {
        let pairs = rb_funcall(val, recorder.id.to_a, 0);
        let len = RARRAY_LEN(pairs) as usize;
        let ptr = RARRAY_CONST_PTR(pairs);
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
        let type_id = TraceWriter::ensure_type_id(&mut *recorder.tracer, TypeKind::Seq, "Hash");
        return ValueRecord::Sequence {
            elements,
            is_slice: false,
            type_id,
        };
    }
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
    if rb_obj_is_kind_of(val, rb_cTime) != 0 {
        let sec = rb_funcall(val, recorder.id.to_i, 0);
        let nsec = rb_funcall(val, recorder.id.nsec, 0);
        return struct_value(recorder, "Time", &["sec", "nsec"], &[sec, nsec], depth);
    }
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
    let class_name = cstr_to_string(rb_obj_classname(val)).unwrap_or_else(|| "Object".to_string());
    // generic object
    let ivars = rb_funcall(val, recorder.id.instance_variables, 0);
    if !RB_TYPE_P(ivars, rb_sys::ruby_value_type::RUBY_T_ARRAY) {
        let text = value_to_string(recorder, val);
        let type_id =
            TraceWriter::ensure_type_id(&mut *recorder.tracer, TypeKind::Raw, &class_name);
        return ValueRecord::Raw { r: text, type_id };
    }
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

unsafe fn record_variables(recorder: &mut Recorder, binding: VALUE) -> Vec<FullValueRecord> {
    let vars = rb_funcall(binding, recorder.id.local_variables, 0);
    if !RB_TYPE_P(vars, rb_sys::ruby_value_type::RUBY_T_ARRAY) {
        return Vec::new();
    }
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

unsafe fn collect_parameter_values(
    recorder: &mut Recorder,
    binding: VALUE,
    defined_class: VALUE,
    mid: ID,
) -> Vec<(String, ValueRecord)> {
    let method_sym = rb_id2sym(mid);
    if rb_method_boundp(defined_class, mid, 0) == 0 {
        return Vec::new();
    }
    let method_obj = rb_funcall(defined_class, recorder.id.instance_method, 1, method_sym);
    let params_ary = rb_funcall(method_obj, recorder.id.parameters, 0);
    if !RB_TYPE_P(params_ary, rb_sys::ruby_value_type::RUBY_T_ARRAY) {
        return Vec::new();
    }
    let params_len = RARRAY_LEN(params_ary) as usize;
    let params_ptr = RARRAY_CONST_PTR(params_ary);
    let mut result = Vec::with_capacity(params_len);
    for i in 0..params_len {
        let pair = *params_ptr.add(i);
        if !RB_TYPE_P(pair, rb_sys::ruby_value_type::RUBY_T_ARRAY) || RARRAY_LEN(pair) < 2 {
            continue;
        }
        let pair_ptr = RARRAY_CONST_PTR(pair);
        let name_sym = *pair_ptr.add(1);
        if NIL_P(name_sym) {
            continue;
        }
        let name_id = rb_sym2id(name_sym);
        let name_c = rb_id2name(name_id);
        if name_c.is_null() {
            continue;
        }
        let name = CStr::from_ptr(name_c).to_str().unwrap_or("").to_string();
        let value = rb_funcall(binding, recorder.id.local_variable_get, 1, name_sym);
        let val_rec = to_value(recorder, value, 10);
        result.push((name, val_rec));
    }
    result
}

unsafe fn register_parameter_values(
    recorder: &mut Recorder,
    params: Vec<(String, ValueRecord)>,
) -> Vec<FullValueRecord> {
    let mut result = Vec::with_capacity(params.len());
    for (name, val_rec) in params {
        TraceWriter::register_variable_with_full_value(
            &mut *recorder.tracer,
            &name,
            val_rec.clone(),
        );
        let var_id = TraceWriter::ensure_variable_id(&mut *recorder.tracer, &name);
        result.push(FullValueRecord {
            variable_id: var_id,
            value: val_rec,
        });
    }
    result
}

unsafe fn record_event(tracer: &mut dyn TraceWriter, path: &str, line: i64, content: String) {
    TraceWriter::register_step(tracer, Path::new(path), Line(line));
    TraceWriter::register_special_event(tracer, EventLogKind::Write, &content)
}

unsafe extern "C" fn initialize(self_val: VALUE, out_dir: VALUE, format: VALUE) -> VALUE {
    let recorder_ptr = get_recorder(self_val);
    let recorder = &mut *recorder_ptr;
    let ptr = RSTRING_PTR(out_dir) as *const u8;
    let len = RSTRING_LEN(out_dir) as usize;
    let slice = std::slice::from_raw_parts(ptr, len);

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

    Qnil.into()
}

unsafe extern "C" fn flush_trace(self_val: VALUE) -> VALUE {
    let recorder_ptr = get_recorder(self_val);
    let recorder = &mut *recorder_ptr;

    if let Err(e) = flush_to_dir(&mut *recorder.tracer) {
        let msg = std::ffi::CString::new(e.to_string())
            .unwrap_or_else(|_| std::ffi::CString::new("unknown error").unwrap());
        rb_raise(
            rb_eIOError,
            b"Failed to flush trace: %s\0".as_ptr() as *const c_char,
            msg.as_ptr(),
        );
    }

    Qnil.into()
}

unsafe extern "C" fn record_event_api(
    self_val: VALUE,
    path: VALUE,
    line: VALUE,
    content: VALUE,
) -> VALUE {
    let recorder = &mut *get_recorder(self_val);
    let path_slice = if NIL_P(path) {
        ""
    } else {
        let ptr = RSTRING_PTR(path);
        let len = RSTRING_LEN(path) as usize;
        std::str::from_utf8(std::slice::from_raw_parts(ptr as *const u8, len)).unwrap_or("")
    };
    let line_num = rb_num2long(line) as i64;
    let content_str = value_to_string(recorder, content);
    record_event(&mut *recorder.tracer, path_slice, line_num, content_str);
    Qnil.into()
}

/// Raw-argument callback (Ruby will call it when we set
/// `RUBY_EVENT_HOOK_FLAG_RAW_ARG`).
///
/// C prototype:
/// ```c
/// void (*)(VALUE data, rb_trace_arg_t *arg);
/// ```
unsafe extern "C" fn event_hook_raw(data: VALUE, arg: *mut rb_trace_arg_t) {
    if arg.is_null() {
        return;
    }

    let recorder = &mut *get_recorder(data);
    if !recorder.active {
        return;
    }

    let ev: rb_event_flag_t = rb_tracearg_event_flag(arg);
    let path_val = rb_tracearg_path(arg);
    let line_val = rb_tracearg_lineno(arg);
    let path = if NIL_P(path_val) {
        ""
    } else {
        let path_bytes = std::slice::from_raw_parts(
            RSTRING_PTR(path_val) as *const u8,
            RSTRING_LEN(path_val) as usize,
        );
        std::str::from_utf8(path_bytes).unwrap_or("")
    };
    let line = rb_num2long(line_val) as i64;
    if should_ignore_path(path) {
        return;
    }

    if (ev & RUBY_EVENT_LINE) != 0 {
        let binding = rb_tracearg_binding(arg);
        TraceWriter::register_step(&mut *recorder.tracer, Path::new(&path), Line(line));
        if !NIL_P(binding) {
            record_variables(recorder, binding);
        }
    } else if (ev & RUBY_EVENT_CALL) != 0 {
        let binding = rb_tracearg_binding(arg);

        let self_val = rb_tracearg_self(arg);
        let mid_sym = rb_tracearg_callee_id(arg);
        let mid = rb_sym2id(mid_sym);
        let defined_class = rb_funcall(self_val, recorder.id.class, 0);

        let param_vals = if NIL_P(binding) {
            Vec::new()
        } else {
            collect_parameter_values(recorder, binding, defined_class, mid)
        };

        let class_name =
            cstr_to_string(rb_obj_classname(self_val)).unwrap_or_else(|| "Object".to_string());
        let text = value_to_string_safe(recorder, self_val);
        let self_type =
            TraceWriter::ensure_type_id(&mut *recorder.tracer, TypeKind::Raw, &class_name);
        let self_rec = ValueRecord::Raw {
            r: text,
            type_id: self_type,
        };
        TraceWriter::register_variable_with_full_value(
            &mut *recorder.tracer,
            "self",
            self_rec.clone(),
        );

        let mut args = vec![TraceWriter::arg(&mut *recorder.tracer, "self", self_rec)];
        if !param_vals.is_empty() {
            args.extend(register_parameter_values(recorder, param_vals));
        }
        TraceWriter::register_step(&mut *recorder.tracer, Path::new(&path), Line(line));
        let name_c = rb_id2name(mid);
        let mut name = if !name_c.is_null() {
            CStr::from_ptr(name_c).to_str().unwrap_or("").to_string()
        } else {
            String::new()
        };
        if class_name != "Object" {
            name = format!("{}#{}", class_name, name);
        }
        let fid = TraceWriter::ensure_function_id(
            &mut *recorder.tracer,
            &name,
            Path::new(&path),
            Line(line),
        );
        TraceWriter::add_event(
            &mut *recorder.tracer,
            TraceLowLevelEvent::Call(CallRecord {
                function_id: fid,
                args,
            }),
        );
    } else if (ev & RUBY_EVENT_RETURN) != 0 {
        TraceWriter::register_step(&mut *recorder.tracer, Path::new(&path), Line(line));
        let ret = rb_tracearg_return_value(arg);
        let val_rec = to_value(recorder, ret, 10);
        TraceWriter::register_variable_with_full_value(
            &mut *recorder.tracer,
            "<return_value>",
            val_rec.clone(),
        );
        TraceWriter::register_return(&mut *recorder.tracer, val_rec);
    } else if (ev & RUBY_EVENT_RAISE) != 0 {
        let exc = rb_tracearg_raised_exception(arg);
        let msg = value_to_string(recorder, exc);
        TraceWriter::register_special_event(&mut *recorder.tracer, EventLogKind::Error, &msg);
    }
}

#[no_mangle]
pub extern "C" fn Init_codetracer_ruby_recorder() {
    unsafe {
        let class = rb_define_class(
            b"CodeTracerNativeRecorder\0".as_ptr() as *const c_char,
            rb_cObject,
        );
        rb_define_alloc_func(class, Some(ruby_recorder_alloc));

        rb_define_method(
            class,
            b"initialize\0".as_ptr() as *const c_char,
            Some(std::mem::transmute(initialize as *const ())),
            2,
        );
        rb_define_method(
            class,
            b"enable_tracing\0".as_ptr() as *const c_char,
            Some(std::mem::transmute(enable_tracing as *const ())),
            0,
        );
        rb_define_method(
            class,
            b"disable_tracing\0".as_ptr() as *const c_char,
            Some(std::mem::transmute(disable_tracing as *const ())),
            0,
        );
        rb_define_method(
            class,
            b"flush_trace\0".as_ptr() as *const c_char,
            Some(std::mem::transmute(flush_trace as *const ())),
            0,
        );
        rb_define_method(
            class,
            b"record_event\0".as_ptr() as *const c_char,
            Some(std::mem::transmute(record_event_api as *const ())),
            3,
        );
    }
}
