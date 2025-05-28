#![allow(clippy::missing_safety_doc)]

use std::{
    ffi::CStr,
    mem::transmute,
    os::raw::{c_char, c_void},
    path::Path,
    ptr,
    collections::HashMap,
};

use rb_sys::{
    rb_add_event_hook2, rb_remove_event_hook_with_data, rb_define_class,
    rb_define_alloc_func, rb_define_method, rb_funcall, rb_intern,
    rb_event_hook_flag_t::RUBY_EVENT_HOOK_FLAG_RAW_ARG,
    rb_event_flag_t, rb_trace_arg_t,
    rb_tracearg_event_flag, rb_tracearg_lineno, rb_tracearg_path, rb_tracearg_self,
    rb_tracearg_binding, rb_tracearg_callee_id, rb_tracearg_return_value,
    rb_tracearg_raised_exception,
    rb_cObject, VALUE, ID, RUBY_EVENT_LINE, RUBY_EVENT_CALL, RUBY_EVENT_RETURN,
    RUBY_EVENT_RAISE,
    rb_raise, rb_eIOError,
    rb_sym2id, rb_id2name, rb_id2sym, rb_obj_classname, rb_num2long
};
use rb_sys::{RARRAY_LEN, RARRAY_CONST_PTR, RSTRING_LEN, RSTRING_PTR, RB_INTEGER_TYPE_P, RB_TYPE_P, RB_SYMBOL_P, RB_FLOAT_TYPE_P, NIL_P, rb_protect};
use rb_sys::{Qtrue, Qfalse, Qnil};
use std::os::raw::c_int;
use runtime_tracing::{
    Tracer, Line, ValueRecord, TypeKind, TypeSpecificInfo, TypeRecord, FieldTypeRecord, TypeId,
    EventLogKind, TraceLowLevelEvent, CallRecord, FullValueRecord, ReturnRecord, RecordEvent,
};

#[repr(C)]
struct RTypedData {
    _basic: [VALUE; 2],
    type_: *const rb_data_type_t,
    typed_flag: VALUE,
    data: *mut c_void,
}

#[repr(C)]
struct rb_data_type_function_struct {
    dmark: Option<unsafe extern "C" fn(*mut c_void)>,
    dfree: Option<unsafe extern "C" fn(*mut c_void)>,
    dsize: Option<unsafe extern "C" fn(*const c_void) -> usize>,
    dcompact: Option<unsafe extern "C" fn(*mut c_void)>,
    reserved: [*mut c_void; 1],
}

#[repr(C)]
struct rb_data_type_t {
    wrap_struct_name: *const c_char,
    function: rb_data_type_function_struct,
    parent: *const rb_data_type_t,
    data: *mut c_void,
    flags: VALUE,
}

extern "C" {
    fn rb_data_typed_object_wrap(
        klass: VALUE,
        datap: *mut c_void,
        data_type: *const rb_data_type_t,
    ) -> VALUE;
    fn rb_check_typeddata(obj: VALUE, data_type: *const rb_data_type_t) -> *mut c_void;
    fn rb_num2dbl(val: VALUE) -> f64;
    fn rb_obj_is_kind_of(obj: VALUE, class: VALUE) -> VALUE;
    fn rb_path2class(path: *const c_char) -> VALUE;
    fn rb_const_defined(klass: VALUE, name: ID) -> VALUE;
    fn rb_const_get(klass: VALUE, name: ID) -> VALUE;
    static rb_cTime: VALUE;
    static rb_cRegexp: VALUE;
    static rb_cStruct: VALUE;
    static rb_cRange: VALUE;
    fn rb_method_boundp(klass: VALUE, mid: ID, ex: c_int) -> VALUE;
}

struct Recorder {
    tracer: Tracer,
    active: bool,
    to_s_id: ID,
    locals_id: ID,
    local_get_id: ID,
    inst_meth_id: ID,
    parameters_id: ID,
    class_id: ID,
    struct_types: HashMap<String, runtime_tracing::TypeId>,
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
    to_s_id: ID,
) -> ValueRecord {
    let mut vals = Vec::new();
    for v in field_values {
        vals.push(to_value(recorder, *v, depth - 1, to_s_id));
    }

    let type_id = if let Some(id) = recorder.struct_types.get(class_name) {
        *id
    } else {
        let field_types: Vec<FieldTypeRecord> = field_names
            .iter()
            .zip(&vals)
            .map(|(n, v)| FieldTypeRecord {
                name: (*n).to_string(),
                type_id: value_type_id(v),
            })
            .collect();
        let typ = TypeRecord {
            kind: TypeKind::Struct,
            lang_type: class_name.to_string(),
            specific_info: TypeSpecificInfo::Struct { fields: field_types },
        };
        let id = recorder.tracer.ensure_raw_type_id(typ);
        recorder.struct_types.insert(class_name.to_string(), id);
        id
    };

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
    function: rb_data_type_function_struct {
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
    rb_check_typeddata(obj, ty) as *mut Recorder
}

unsafe extern "C" fn ruby_recorder_alloc(klass: VALUE) -> VALUE {
    let mut tracer = Tracer::new("ruby", &vec![]);
    // pre-register common types to match the pure Ruby tracer
    tracer.ensure_type_id(TypeKind::Int, "Integer");
    tracer.ensure_type_id(TypeKind::String, "String");
    tracer.ensure_type_id(TypeKind::Bool, "Bool");
    tracer.ensure_type_id(TypeKind::String, "Symbol");
    tracer.ensure_type_id(TypeKind::Error, "No type");
    let path = Path::new("");
    let func_id = tracer.ensure_function_id("<top-level>", path, Line(1));
    tracer.events.push(TraceLowLevelEvent::Call(CallRecord { function_id: func_id, args: vec![] }));
    let to_s_id = rb_intern(b"to_s\0".as_ptr() as *const c_char);
    let locals_id = rb_intern(b"local_variables\0".as_ptr() as *const c_char);
    let local_get_id = rb_intern(b"local_variable_get\0".as_ptr() as *const c_char);
    let inst_meth_id = rb_intern(b"instance_method\0".as_ptr() as *const c_char);
    let parameters_id = rb_intern(b"parameters\0".as_ptr() as *const c_char);
    let class_id = rb_intern(b"class\0".as_ptr() as *const c_char);
    let recorder = Box::new(Recorder {
        tracer,
        active: false,
        to_s_id,
        locals_id,
        local_get_id,
        inst_meth_id,
        parameters_id,
        class_id,
        struct_types: HashMap::new(),
    });
    let ty = std::ptr::addr_of!(RECORDER_TYPE) as *const rb_data_type_t;
    rb_data_typed_object_wrap(klass, Box::into_raw(recorder) as *mut c_void, ty)
}

unsafe extern "C" fn enable_tracing(self_val: VALUE) -> VALUE {
    let recorder = &mut *get_recorder(self_val);
    if !recorder.active {
        let raw_cb: unsafe extern "C" fn(VALUE, *mut rb_trace_arg_t) = event_hook_raw;
        let cb: unsafe extern "C" fn(rb_event_flag_t, VALUE, VALUE, ID, VALUE) = transmute(raw_cb);
        rb_add_event_hook2(
            Some(cb),
            RUBY_EVENT_LINE | RUBY_EVENT_CALL | RUBY_EVENT_RETURN | RUBY_EVENT_RAISE,
            self_val,
            RUBY_EVENT_HOOK_FLAG_RAW_ARG,
        );
        recorder.active = true;
    }
    rb_sys::Qnil.into()
}

unsafe extern "C" fn disable_tracing(self_val: VALUE) -> VALUE {
    let recorder = &mut *get_recorder(self_val);
    if recorder.active {
        let raw_cb: unsafe extern "C" fn(VALUE, *mut rb_trace_arg_t) = event_hook_raw;
        let cb: unsafe extern "C" fn(rb_event_flag_t, VALUE, VALUE, ID, VALUE) = transmute(raw_cb);
        rb_remove_event_hook_with_data(Some(cb), self_val);
        recorder.active = false;
    }
    rb_sys::Qnil.into()
}

fn flush_to_dir(tracer: &Tracer, dir: &Path) -> Result<(), Box<dyn std::error::Error>> {
    std::fs::create_dir_all(dir)?;
    let events = dir.join("trace.json");
    let metadata = dir.join("trace_metadata.json");
    let paths = dir.join("trace_paths.json");
    tracer.store_trace_events(&events)?;
    tracer.store_trace_metadata(&metadata)?;
    tracer.store_trace_paths(&paths)?;
    Ok(())
}

unsafe fn cstr_to_string(ptr: *const c_char) -> Option<String> {
    if ptr.is_null() {
        return None;
    }
    CStr::from_ptr(ptr).to_str().ok().map(|s| s.to_string())
}

unsafe fn value_to_string(val: VALUE, to_s_id: ID) -> Option<String> {
    if RB_TYPE_P(val, rb_sys::ruby_value_type::RUBY_T_STRING) {
        let ptr = RSTRING_PTR(val);
        let len = RSTRING_LEN(val) as usize;
        let slice = std::slice::from_raw_parts(ptr as *const u8, len);
        return Some(String::from_utf8_lossy(slice).to_string());
    }
    let str_val = rb_funcall(val, to_s_id, 0);
    let ptr = RSTRING_PTR(str_val);
    let len = RSTRING_LEN(str_val) as usize;
    let slice = std::slice::from_raw_parts(ptr as *const u8, len);
    Some(String::from_utf8_lossy(slice).to_string())
}

unsafe extern "C" fn call_to_s(arg: VALUE) -> VALUE {
    let data = &*(arg as *const (VALUE, ID));
    rb_funcall(data.0, data.1, 0)
}

unsafe fn value_to_string_safe(val: VALUE, to_s_id: ID) -> Option<String> {
    if RB_TYPE_P(val, rb_sys::ruby_value_type::RUBY_T_STRING) {
        let ptr = RSTRING_PTR(val);
        let len = RSTRING_LEN(val) as usize;
        let slice = std::slice::from_raw_parts(ptr as *const u8, len);
        return Some(String::from_utf8_lossy(slice).to_string());
    }
    let mut state: c_int = 0;
    let data = (val, to_s_id);
    let str_val = rb_protect(Some(call_to_s), &data as *const _ as VALUE, &mut state);
    if state != 0 {
        return None;
    }
    let ptr = RSTRING_PTR(str_val);
    let len = RSTRING_LEN(str_val) as usize;
    let slice = std::slice::from_raw_parts(ptr as *const u8, len);
    Some(String::from_utf8_lossy(slice).to_string())
}

unsafe fn to_value(recorder: &mut Recorder, val: VALUE, depth: usize, to_s_id: ID) -> ValueRecord {
    if depth == 0 {
        let type_id = recorder.tracer.ensure_type_id(TypeKind::Error, "No type");
        return ValueRecord::None { type_id };
    }
    if NIL_P(val) {
        let type_id = recorder.tracer.ensure_type_id(TypeKind::Error, "No type");
        return ValueRecord::None { type_id };
    }
    if val == (Qtrue as VALUE) || val == (Qfalse as VALUE) {
        let type_id = recorder.tracer.ensure_type_id(TypeKind::Bool, "Bool");
        return ValueRecord::Bool { b: val == (Qtrue as VALUE), type_id };
    }
    if RB_INTEGER_TYPE_P(val) {
        let i = rb_num2long(val) as i64;
        let type_id = recorder.tracer.ensure_type_id(TypeKind::Int, "Integer");
        return ValueRecord::Int { i, type_id };
    }
    if RB_FLOAT_TYPE_P(val) {
        let f = rb_num2dbl(val);
        let type_id = recorder.tracer.ensure_type_id(TypeKind::Float, "Float");
        return ValueRecord::Float { f, type_id };
    }
    if RB_SYMBOL_P(val) {
        let id = rb_sym2id(val);
        let name = CStr::from_ptr(rb_id2name(id)).to_str().unwrap_or("");
        let type_id = recorder.tracer.ensure_type_id(TypeKind::String, "Symbol");
        return ValueRecord::String { text: name.to_string(), type_id };
    }
    if RB_TYPE_P(val, rb_sys::ruby_value_type::RUBY_T_STRING) {
        let ptr = RSTRING_PTR(val);
        let len = RSTRING_LEN(val) as usize;
        let slice = std::slice::from_raw_parts(ptr as *const u8, len);
        let type_id = recorder.tracer.ensure_type_id(TypeKind::String, "String");
        return ValueRecord::String { text: String::from_utf8_lossy(slice).to_string(), type_id };
    }
    if RB_TYPE_P(val, rb_sys::ruby_value_type::RUBY_T_ARRAY) {
        let len = RARRAY_LEN(val) as usize;
        let mut elements = Vec::new();
        let ptr = RARRAY_CONST_PTR(val);
        for i in 0..len {
            let elem = *ptr.add(i);
            elements.push(to_value(recorder, elem, depth - 1, to_s_id));
        }
        let type_id = recorder.tracer.ensure_type_id(TypeKind::Seq, "Array");
        return ValueRecord::Sequence { elements, is_slice: false, type_id };
    }
    if RB_TYPE_P(val, rb_sys::ruby_value_type::RUBY_T_HASH) {
        let pairs = rb_funcall(val, rb_intern(b"to_a\0".as_ptr() as *const c_char), 0);
        let len = RARRAY_LEN(pairs) as usize;
        let ptr = RARRAY_CONST_PTR(pairs);
        let mut elements = Vec::new();
        for i in 0..len {
            let pair = *ptr.add(i);
            if !RB_TYPE_P(pair, rb_sys::ruby_value_type::RUBY_T_ARRAY) || RARRAY_LEN(pair) < 2 {
                continue;
            }
            let pair_ptr = RARRAY_CONST_PTR(pair);
            let key = *pair_ptr.add(0);
            let val_elem = *pair_ptr.add(1);
            elements.push(struct_value(recorder, "Pair", &["k", "v"], &[key, val_elem], depth, to_s_id));
        }
        let type_id = recorder.tracer.ensure_type_id(TypeKind::Seq, "Hash");
        return ValueRecord::Sequence { elements, is_slice: false, type_id };
    }
    if rb_obj_is_kind_of(val, rb_cRange) != 0 {
        let begin_val = rb_funcall(val, rb_intern(b"begin\0".as_ptr() as *const c_char), 0);
        let end_val = rb_funcall(val, rb_intern(b"end\0".as_ptr() as *const c_char), 0);
        return struct_value(recorder, "Range", &["begin", "end"], &[begin_val, end_val], depth, to_s_id);
    }
    let set_id = rb_intern(b"Set\0".as_ptr() as *const c_char);
    if rb_const_defined(rb_cObject, set_id) != 0 {
        let set_cls = rb_const_get(rb_cObject, set_id);
        if rb_obj_is_kind_of(val, set_cls) != 0 {
            let arr = rb_funcall(val, rb_intern(b"to_a\0".as_ptr() as *const c_char), 0);
            if RB_TYPE_P(arr, rb_sys::ruby_value_type::RUBY_T_ARRAY) {
                let len = RARRAY_LEN(arr) as usize;
                let ptr = RARRAY_CONST_PTR(arr);
                let mut elements = Vec::new();
                for i in 0..len {
                    let elem = *ptr.add(i);
                    elements.push(to_value(recorder, elem, depth - 1, to_s_id));
                }
                let type_id = recorder.tracer.ensure_type_id(TypeKind::Seq, "Set");
                return ValueRecord::Sequence { elements, is_slice: false, type_id };
            }
        }
    }
    if rb_obj_is_kind_of(val, rb_cTime) != 0 {
        let sec = rb_funcall(val, rb_intern(b"to_i\0".as_ptr() as *const c_char), 0);
        let nsec = rb_funcall(val, rb_intern(b"nsec\0".as_ptr() as *const c_char), 0);
        return struct_value(recorder, "Time", &["sec", "nsec"], &[sec, nsec], depth, to_s_id);
    }
    if rb_obj_is_kind_of(val, rb_cRegexp) != 0 {
        let src = rb_funcall(val, rb_intern(b"source\0".as_ptr() as *const c_char), 0);
        let opts = rb_funcall(val, rb_intern(b"options\0".as_ptr() as *const c_char), 0);
        return struct_value(recorder, "Regexp", &["source", "options"], &[src, opts], depth, to_s_id);
    }
    if rb_obj_is_kind_of(val, rb_cStruct) != 0 {
        let class_name = cstr_to_string(rb_obj_classname(val)).unwrap_or_else(|| "Struct".to_string());
        let members = rb_funcall(val, rb_intern(b"members\0".as_ptr() as *const c_char), 0);
        let values = rb_funcall(val, rb_intern(b"values\0".as_ptr() as *const c_char), 0);
        if !RB_TYPE_P(members, rb_sys::ruby_value_type::RUBY_T_ARRAY) || !RB_TYPE_P(values, rb_sys::ruby_value_type::RUBY_T_ARRAY) {
            let text = value_to_string(val, to_s_id).unwrap_or_default();
            let type_id = recorder.tracer.ensure_type_id(TypeKind::Raw, &class_name);
            return ValueRecord::Raw { r: text, type_id };
        }
        let len = RARRAY_LEN(values) as usize;
        let mem_ptr = RARRAY_CONST_PTR(members);
        let val_ptr = RARRAY_CONST_PTR(values);
        let mut names: Vec<&str> = Vec::new();
        let mut vals: Vec<VALUE> = Vec::new();
        for i in 0..len {
            let sym = *mem_ptr.add(i);
            let id = rb_sym2id(sym);
            let cstr = rb_id2name(id);
            let name = CStr::from_ptr(cstr).to_str().unwrap_or("?");
            names.push(name);
            vals.push(*val_ptr.add(i));
        }
        return struct_value(recorder, &class_name, &names, &vals, depth, to_s_id);
    }
    let open_struct_id = rb_intern(b"OpenStruct\0".as_ptr() as *const c_char);
    if rb_const_defined(rb_cObject, open_struct_id) != 0 {
        let open_struct = rb_const_get(rb_cObject, open_struct_id);
        if rb_obj_is_kind_of(val, open_struct) != 0 {
            let h = rb_funcall(val, rb_intern(b"to_h\0".as_ptr() as *const c_char), 0);
            return to_value(recorder, h, depth - 1, to_s_id);
        }
    }
    let class_name = cstr_to_string(rb_obj_classname(val)).unwrap_or_else(|| "Object".to_string());
    // generic object
    let ivars = rb_funcall(val, rb_intern(b"instance_variables\0".as_ptr() as *const c_char), 0);
    if !RB_TYPE_P(ivars, rb_sys::ruby_value_type::RUBY_T_ARRAY) {
        let text = value_to_string(val, to_s_id).unwrap_or_default();
        let type_id = recorder.tracer.ensure_type_id(TypeKind::Raw, &class_name);
        return ValueRecord::Raw { r: text, type_id };
    }
    let len = RARRAY_LEN(ivars) as usize;
    let ptr = RARRAY_CONST_PTR(ivars);
    let mut names: Vec<&str> = Vec::new();
    let mut vals: Vec<VALUE> = Vec::new();
    for i in 0..len {
        let sym = *ptr.add(i);
        let id = rb_sym2id(sym);
        let cstr = rb_id2name(id);
        let name = CStr::from_ptr(cstr).to_str().unwrap_or("?");
        names.push(name);
        let value = rb_funcall(val, rb_intern(b"instance_variable_get\0".as_ptr() as *const c_char), 1, sym);
        vals.push(value);
    }
    if !names.is_empty() {
        return struct_value(recorder, &class_name, &names, &vals, depth, to_s_id);
    }
    let text = value_to_string(val, to_s_id).unwrap_or_default();
    let type_id = recorder.tracer.ensure_type_id(TypeKind::Raw, &class_name);
    ValueRecord::Raw { r: text, type_id }
}

unsafe fn record_variables(recorder: &mut Recorder, binding: VALUE) -> Vec<FullValueRecord> {
    let mut result = Vec::new();
    let vars = rb_funcall(binding, recorder.locals_id, 0);
    if !RB_TYPE_P(vars, rb_sys::ruby_value_type::RUBY_T_ARRAY) {
        return result;
    }
    let len = RARRAY_LEN(vars) as usize;
    let ptr = RARRAY_CONST_PTR(vars);
    for i in 0..len {
        let sym = *ptr.add(i);
        let id = rb_sym2id(sym);
        let name = CStr::from_ptr(rb_id2name(id)).to_str().unwrap_or("");
        let value = rb_funcall(binding, recorder.local_get_id, 1, sym);
        let val_rec = to_value(recorder, value, 10, recorder.to_s_id);
        recorder.tracer.register_variable_with_full_value(name, val_rec.clone());
        let var_id = recorder.tracer.ensure_variable_id(name);
        result.push(FullValueRecord { variable_id: var_id, value: val_rec });
    }
    result
}

unsafe fn record_parameters(recorder: &mut Recorder, binding: VALUE, defined_class: VALUE, mid: ID, register: bool) -> Vec<FullValueRecord> {
    let mut result = Vec::new();
    let method_sym = rb_id2sym(mid);
    if rb_method_boundp(defined_class, mid, 0) == 0 {
        return result;
    }
    let method_obj = rb_funcall(defined_class, recorder.inst_meth_id, 1, method_sym);
    let params_ary = rb_funcall(method_obj, recorder.parameters_id, 0);
    if !RB_TYPE_P(params_ary, rb_sys::ruby_value_type::RUBY_T_ARRAY) {
        return result;
    }
    let params_len = RARRAY_LEN(params_ary) as usize;
    let params_ptr = RARRAY_CONST_PTR(params_ary);
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
        let name = CStr::from_ptr(name_c).to_str().unwrap_or("");
        let value = rb_funcall(binding, recorder.local_get_id, 1, name_sym);
        let val_rec = to_value(recorder, value, 10, recorder.to_s_id);
        if register {
            recorder.tracer.register_variable_with_full_value(name, val_rec.clone());
            let var_id = recorder.tracer.ensure_variable_id(name);
            result.push(FullValueRecord { variable_id: var_id, value: val_rec });
        }
    }
    result
}

unsafe fn record_event(tracer: &mut Tracer, path: &str, line: i64, content: &str) {
    tracer.register_step(Path::new(path), Line(line));
    tracer.events.push(TraceLowLevelEvent::Event(RecordEvent {
        kind: EventLogKind::Write,
        metadata: String::new(),
        content: content.to_string(),
    }));
}

unsafe extern "C" fn flush_trace(self_val: VALUE, out_dir: VALUE) -> VALUE {
    let recorder_ptr = get_recorder(self_val);
    let recorder = &mut *recorder_ptr;
    let ptr = RSTRING_PTR(out_dir) as *const u8;
    let len = RSTRING_LEN(out_dir) as usize;
    let slice = std::slice::from_raw_parts(ptr, len);

    match std::str::from_utf8(slice) {
        Ok(path_str) => {
            if let Err(e) = flush_to_dir(&recorder.tracer, Path::new(path_str)) {
                rb_raise(rb_eIOError, b"Failed to flush trace: %s\0".as_ptr() as *const c_char, e.to_string().as_ptr() as *const c_char);
            }
        }
        Err(e) => rb_raise(rb_eIOError, b"Invalid UTF-8 in path: %s\0".as_ptr() as *const c_char, e.to_string().as_ptr() as *const c_char),
    }

    rb_sys::Qnil.into()
}

unsafe extern "C" fn record_event_api(self_val: VALUE, path: VALUE, line: VALUE, content: VALUE) -> VALUE {
    let recorder = &mut *get_recorder(self_val);
    let path_str = if NIL_P(path) {
        "".to_string()
    } else {
        let ptr = RSTRING_PTR(path);
        let len = RSTRING_LEN(path) as usize;
        String::from_utf8_lossy(std::slice::from_raw_parts(ptr as *const u8, len)).to_string()
    };
    let line_num = rb_num2long(line) as i64;
    let content_str = value_to_string(content, recorder.to_s_id).unwrap_or_default();
    record_event(&mut recorder.tracer, &path_str, line_num, &content_str);
    rb_sys::Qnil.into()
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
        "".to_string()
    } else {
        let ptr = RSTRING_PTR(path_val);
        let len = RSTRING_LEN(path_val) as usize;
        String::from_utf8_lossy(std::slice::from_raw_parts(ptr as *const u8, len)).to_string()
    };
    let line = rb_num2long(line_val) as i64;
    if path.contains("native_trace.rb") {
        return;
    }

    if (ev & RUBY_EVENT_LINE) != 0 {
        let binding = rb_tracearg_binding(arg);
        recorder.tracer.register_step(Path::new(&path), Line(line));
        if !NIL_P(binding) {
            record_variables(recorder, binding);
        }
    } else if (ev & RUBY_EVENT_CALL) != 0 {
        let binding = rb_tracearg_binding(arg);

        let self_val = rb_tracearg_self(arg);
        let mid_sym = rb_tracearg_callee_id(arg);
        let mid = rb_sym2id(mid_sym);
        let defined_class = rb_funcall(self_val, recorder.class_id, 0);
        let mut args = Vec::new();
        if !NIL_P(binding) {
            args = record_parameters(recorder, binding, defined_class, mid, true);
        }
        let class_name = cstr_to_string(rb_obj_classname(self_val)).unwrap_or_else(|| "Object".to_string());
        let text = value_to_string_safe(self_val, recorder.to_s_id).unwrap_or_default();
        let self_type = recorder.tracer.ensure_type_id(TypeKind::Raw, &class_name);
        let self_rec = ValueRecord::Raw { r: text, type_id: self_type };
        recorder
            .tracer
            .register_variable_with_full_value("self", self_rec.clone());

        args.insert(0, recorder.tracer.arg("self", self_rec));
        recorder.tracer.register_step(Path::new(&path), Line(line));
        let name_c = rb_id2name(mid);
        let mut name = if !name_c.is_null() {
            CStr::from_ptr(name_c).to_str().unwrap_or("").to_string()
        } else {
            String::new()
        };
        if class_name != "Object" {
            name = format!("{}#{}", class_name, name);
        }
        let fid = recorder.tracer.ensure_function_id(&name, Path::new(&path), Line(line));
        recorder.tracer.events.push(TraceLowLevelEvent::Call(CallRecord { function_id: fid, args }));
    } else if (ev & RUBY_EVENT_RETURN) != 0 {
        recorder.tracer.register_step(Path::new(&path), Line(line));
        let ret = rb_tracearg_return_value(arg);
        let val_rec = to_value(recorder, ret, 10, recorder.to_s_id);
        recorder.tracer.register_variable_with_full_value("<return_value>", val_rec.clone());
        recorder.tracer.events.push(TraceLowLevelEvent::Return(ReturnRecord { return_value: val_rec }));
    } else if (ev & RUBY_EVENT_RAISE) != 0 {
        let exc = rb_tracearg_raised_exception(arg);
        if let Some(msg) = value_to_string(exc, recorder.to_s_id) {
            recorder.tracer.events.push(TraceLowLevelEvent::Event(RecordEvent {
                kind: EventLogKind::Error,
                metadata: String::new(),
                content: msg,
            }));
        }
    }
}

#[no_mangle]
pub extern "C" fn Init_codetracer_ruby_recorder() {
    unsafe {
        let class = rb_define_class(b"RubyRecorder\0".as_ptr() as *const c_char, rb_cObject);
        rb_define_alloc_func(class, Some(ruby_recorder_alloc));
        let enable_cb: unsafe extern "C" fn(VALUE) -> VALUE = enable_tracing;
        let disable_cb: unsafe extern "C" fn(VALUE) -> VALUE = disable_tracing;
        let flush_cb: unsafe extern "C" fn(VALUE, VALUE) -> VALUE = flush_trace;
        let event_cb: unsafe extern "C" fn(VALUE, VALUE, VALUE, VALUE) -> VALUE = record_event_api;
        rb_define_method(class, b"enable_tracing\0".as_ptr() as *const c_char, Some(transmute(enable_cb)), 0);
        rb_define_method(class, b"disable_tracing\0".as_ptr() as *const c_char, Some(transmute(disable_cb)), 0);
        rb_define_method(class, b"flush_trace\0".as_ptr() as *const c_char, Some(transmute(flush_cb)), 1);
        rb_define_method(class, b"record_event\0".as_ptr() as *const c_char, Some(transmute(event_cb)), 3);
    }
}
