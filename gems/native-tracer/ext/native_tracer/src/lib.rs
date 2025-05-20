#![allow(clippy::missing_safety_doc)]

use std::{
    ffi::CStr,
    mem::transmute,
    os::raw::{c_char, c_void},
    path::Path,
    ptr,
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
    rb_sym2id, rb_id2name, rb_obj_classname, rb_num2long
};
use rb_sys::{RARRAY_LEN, RARRAY_CONST_PTR, RSTRING_LEN, RSTRING_PTR, RB_INTEGER_TYPE_P, RB_TYPE_P, RB_SYMBOL_P, NIL_P};
use rb_sys::{Qtrue, Qfalse, Qnil};
use runtime_tracing::{Tracer, Line, ValueRecord, TypeKind, EventLogKind, TraceLowLevelEvent, CallRecord, FullValueRecord, ReturnRecord, RecordEvent};

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
}

struct Recorder {
    tracer: Tracer,
    active: bool,
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
    let recorder = Box::new(Recorder { tracer, active: false });
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

unsafe fn value_to_string(val: VALUE) -> Option<String> {
    if RB_TYPE_P(val, rb_sys::ruby_value_type::RUBY_T_STRING) {
        let ptr = RSTRING_PTR(val);
        let len = RSTRING_LEN(val) as usize;
        let slice = std::slice::from_raw_parts(ptr as *const u8, len);
        return Some(String::from_utf8_lossy(slice).to_string());
    }
    let to_s_id = rb_intern(b"to_s\0".as_ptr() as *const c_char);
    let str_val = rb_funcall(val, to_s_id, 0);
    let ptr = RSTRING_PTR(str_val);
    let len = RSTRING_LEN(str_val) as usize;
    let slice = std::slice::from_raw_parts(ptr as *const u8, len);
    Some(String::from_utf8_lossy(slice).to_string())
}

unsafe fn to_value(tracer: &mut Tracer, val: VALUE, depth: usize) -> ValueRecord {
    if depth == 0 {
        let type_id = tracer.ensure_type_id(TypeKind::Error, "No type");
        return ValueRecord::None { type_id };
    }
    if NIL_P(val) {
        let type_id = tracer.ensure_type_id(TypeKind::Error, "No type");
        return ValueRecord::None { type_id };
    }
    if val == (Qtrue as VALUE) || val == (Qfalse as VALUE) {
        let type_id = tracer.ensure_type_id(TypeKind::Bool, "Bool");
        return ValueRecord::Bool { b: val == (Qtrue as VALUE), type_id };
    }
    if RB_INTEGER_TYPE_P(val) {
        let i = rb_num2long(val) as i64;
        let type_id = tracer.ensure_type_id(TypeKind::Int, "Integer");
        return ValueRecord::Int { i, type_id };
    }
    if RB_SYMBOL_P(val) {
        let id = rb_sym2id(val);
        let name = CStr::from_ptr(rb_id2name(id)).to_str().unwrap_or("");
        let type_id = tracer.ensure_type_id(TypeKind::String, "Symbol");
        return ValueRecord::String { text: name.to_string(), type_id };
    }
    if RB_TYPE_P(val, rb_sys::ruby_value_type::RUBY_T_STRING) {
        let ptr = RSTRING_PTR(val);
        let len = RSTRING_LEN(val) as usize;
        let slice = std::slice::from_raw_parts(ptr as *const u8, len);
        let type_id = tracer.ensure_type_id(TypeKind::String, "String");
        return ValueRecord::String { text: String::from_utf8_lossy(slice).to_string(), type_id };
    }
    if RB_TYPE_P(val, rb_sys::ruby_value_type::RUBY_T_ARRAY) {
        let len = RARRAY_LEN(val) as usize;
        let mut elements = Vec::new();
        let ptr = RARRAY_CONST_PTR(val);
        for i in 0..len {
            let elem = *ptr.add(i);
            elements.push(to_value(tracer, elem, depth - 1));
        }
        let type_id = tracer.ensure_type_id(TypeKind::Seq, "Array");
        return ValueRecord::Sequence { elements, is_slice: false, type_id };
    }
    let class_name = cstr_to_string(rb_obj_classname(val)).unwrap_or_else(|| "Object".to_string());
    let text = value_to_string(val).unwrap_or_default();
    let type_id = tracer.ensure_type_id(TypeKind::Raw, &class_name);
    ValueRecord::Raw { r: text, type_id }
}

unsafe fn record_variables(tracer: &mut Tracer, binding: VALUE) -> Vec<FullValueRecord> {
    let mut result = Vec::new();
    let locals_id = rb_intern(b"local_variables\0".as_ptr() as *const c_char);
    let get_id = rb_intern(b"local_variable_get\0".as_ptr() as *const c_char);
    let vars = rb_funcall(binding, locals_id, 0);
    let len = RARRAY_LEN(vars) as usize;
    let ptr = RARRAY_CONST_PTR(vars);
    for i in 0..len {
        let sym = *ptr.add(i);
        let id = rb_sym2id(sym);
        let name = CStr::from_ptr(rb_id2name(id)).to_str().unwrap_or("");
        let value = rb_funcall(binding, get_id, 1, sym);
        let val_rec = to_value(tracer, value, 10);
        tracer.register_variable_with_full_value(name, val_rec.clone());
        let var_id = tracer.ensure_variable_id(name);
        result.push(FullValueRecord { variable_id: var_id, value: val_rec });
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
    let content_str = value_to_string(content).unwrap_or_default();
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
            record_variables(&mut recorder.tracer, binding);
        }
    } else if (ev & RUBY_EVENT_CALL) != 0 {
        recorder.tracer.register_step(Path::new(&path), Line(line));
        let binding = rb_tracearg_binding(arg);
        let mut args = Vec::new();
        let self_val = rb_tracearg_self(arg);
        let self_rec = to_value(&mut recorder.tracer, self_val, 10);
        recorder.tracer.register_variable_with_full_value("self", self_rec.clone());
        args.push(recorder.tracer.arg("self", self_rec));
        if !NIL_P(binding) {
            let mut other = record_variables(&mut recorder.tracer, binding);
            args.append(&mut other);
        }
        let mid_sym = rb_tracearg_callee_id(arg);
        let mid = rb_sym2id(mid_sym);
        let name_c = rb_id2name(mid);
        let mut name = if !name_c.is_null() {
            CStr::from_ptr(name_c).to_str().unwrap_or("").to_string()
        } else {
            String::new()
        };
        let class_name = cstr_to_string(rb_obj_classname(self_val)).unwrap_or_else(|| "Object".to_string());
        if class_name != "Object" {
            name = format!("{}#{}", class_name, name);
        }
        let fid = recorder.tracer.ensure_function_id(&name, Path::new(&path), Line(line));
        recorder.tracer.events.push(TraceLowLevelEvent::Call(CallRecord { function_id: fid, args }));
    } else if (ev & RUBY_EVENT_RETURN) != 0 {
        recorder.tracer.register_step(Path::new(&path), Line(line));
        let ret = rb_tracearg_return_value(arg);
        let val_rec = to_value(&mut recorder.tracer, ret, 10);
        recorder.tracer.register_variable_with_full_value("<return_value>", val_rec.clone());
        recorder.tracer.events.push(TraceLowLevelEvent::Return(ReturnRecord { return_value: val_rec }));
    } else if (ev & RUBY_EVENT_RAISE) != 0 {
        let exc = rb_tracearg_raised_exception(arg);
        if let Some(msg) = value_to_string(exc) {
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
