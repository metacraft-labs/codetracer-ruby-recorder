#![allow(clippy::missing_safety_doc)]

use std::{
    ffi::CStr,
    mem::transmute,
    os::raw::{c_char, c_void},
    path::Path,
    ptr,
    sync::Mutex,
};

use rb_sys::{
    rb_add_event_hook2, rb_remove_event_hook_with_data, rb_define_class,
    rb_define_alloc_func, rb_define_method,
    rb_event_hook_flag_t::RUBY_EVENT_HOOK_FLAG_RAW_ARG,
    rb_event_flag_t, rb_trace_arg_t,
    rb_tracearg_event_flag, rb_tracearg_lineno, rb_tracearg_path,
    rb_cObject, VALUE, ID, RUBY_EVENT_LINE,
    RSTRING_PTR, RSTRING_LEN,
};
use runtime_tracing::{Tracer, Line};

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
    tracer: Mutex<Tracer>,
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
    let recorder = Box::new(Recorder { tracer: Mutex::new(Tracer::new("ruby", &vec![])), active: false });
    let ty = std::ptr::addr_of!(RECORDER_TYPE) as *const rb_data_type_t;
    rb_data_typed_object_wrap(klass, Box::into_raw(recorder) as *mut c_void, ty)
}

unsafe extern "C" fn ruby_recorder_initialize(_self: VALUE) -> VALUE {
    // nothing special for now
    rb_sys::Qnil.into()
}

unsafe extern "C" fn enable_tracing(self_val: VALUE) -> VALUE {
    let recorder = &mut *get_recorder(self_val);
    if !recorder.active {
        let raw_cb: unsafe extern "C" fn(VALUE, *mut rb_trace_arg_t) = event_hook_raw;
        let cb: unsafe extern "C" fn(rb_event_flag_t, VALUE, VALUE, ID, VALUE) = transmute(raw_cb);
        rb_add_event_hook2(Some(cb), RUBY_EVENT_LINE, self_val, RUBY_EVENT_HOOK_FLAG_RAW_ARG);
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

fn flush_to_dir(tracer: &Tracer, dir: &Path) {
    let _ = std::fs::create_dir_all(dir);
    let events = dir.join("trace.json");
    let metadata = dir.join("trace_metadata.json");
    let paths = dir.join("trace_paths.json");
    let _ = tracer.store_trace_events(&events);
    let _ = tracer.store_trace_metadata(&metadata);
    let _ = tracer.store_trace_paths(&paths);
}

unsafe extern "C" fn flush_trace(self_val: VALUE, out_dir: VALUE) -> VALUE {
    let recorder_ptr = get_recorder(self_val);
    let recorder = &mut *recorder_ptr;
    let ptr = RSTRING_PTR(out_dir) as *const u8;
    let len = RSTRING_LEN(out_dir) as usize;
    let slice = std::slice::from_raw_parts(ptr, len);
    if let Ok(path_str) = std::str::from_utf8(slice) {
        if let Ok(t) = recorder.tracer.lock() {
            flush_to_dir(&t, Path::new(path_str));
        }
    }
    drop(Box::from_raw(recorder_ptr));
    let rdata = self_val as *mut RTypedData;
    (*rdata).data = ptr::null_mut();
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
    if (ev & RUBY_EVENT_LINE) == 0 {
        return;
    }

    let path_ptr = rb_tracearg_path(arg) as *const c_char;
    let line = rb_tracearg_lineno(arg) as i64;

    if !path_ptr.is_null() {
        if let Ok(path) = CStr::from_ptr(path_ptr).to_str() {
            if let Ok(mut t) = recorder.tracer.lock() {
                t.register_step(Path::new(path), Line(line));
            }
        }
    }
}

#[no_mangle]
pub extern "C" fn Init_codetracer_ruby_recorder() {
    unsafe {
        let class = rb_define_class(b"RubyRecorder\0".as_ptr() as *const c_char, rb_cObject);
        rb_define_alloc_func(class, Some(ruby_recorder_alloc));
        let init_cb: unsafe extern "C" fn(VALUE) -> VALUE = ruby_recorder_initialize;
        let enable_cb: unsafe extern "C" fn(VALUE) -> VALUE = enable_tracing;
        let disable_cb: unsafe extern "C" fn(VALUE) -> VALUE = disable_tracing;
        let flush_cb: unsafe extern "C" fn(VALUE, VALUE) -> VALUE = flush_trace;
        rb_define_method(class, b"initialize\0".as_ptr() as *const c_char, Some(transmute(init_cb)), 0);
        rb_define_method(class, b"enable_tracing\0".as_ptr() as *const c_char, Some(transmute(enable_cb)), 0);
        rb_define_method(class, b"disable_tracing\0".as_ptr() as *const c_char, Some(transmute(disable_cb)), 0);
        rb_define_method(class, b"flush_trace\0".as_ptr() as *const c_char, Some(transmute(flush_cb)), 1);
    }
}
