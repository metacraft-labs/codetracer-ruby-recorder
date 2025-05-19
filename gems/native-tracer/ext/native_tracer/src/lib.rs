#![allow(clippy::missing_safety_doc)]

use std::{
    ffi::{CStr, CString},
    mem::transmute,
    os::raw::{c_char, c_int, c_void},
    path::{Path, PathBuf},
    ptr,
    sync::{Mutex},
};

use rb_sys::{
    rb_add_event_hook2, rb_remove_event_hook_with_data, rb_define_class,
    rb_define_alloc_func, rb_define_method, rb_obj_alloc,
    rb_ivar_set, rb_ivar_get, rb_intern, rb_ull2inum, rb_num2ull,
    rb_event_hook_flag_t::RUBY_EVENT_HOOK_FLAG_RAW_ARG,
    rb_event_flag_t, rb_trace_arg_t,
    rb_tracearg_event_flag, rb_tracearg_lineno, rb_tracearg_path,
    rb_cObject, VALUE, ID, RUBY_EVENT_LINE,
    RSTRING_PTR, RSTRING_LEN,
};
use runtime_tracing::{Tracer, Line};

struct Recorder {
    tracer: Mutex<Tracer>,
    active: bool,
}

static mut PTR_IVAR: ID = 0;

unsafe fn get_recorder(obj: VALUE) -> *mut Recorder {
    let val = rb_ivar_get(obj, PTR_IVAR);
    rb_num2ull(val) as *mut Recorder
}

unsafe extern "C" fn ruby_recorder_alloc(klass: VALUE) -> VALUE {
    let obj = rb_obj_alloc(klass);
    let recorder = Box::new(Recorder { tracer: Mutex::new(Tracer::new("ruby", &vec![])), active: false });
    rb_ivar_set(obj, PTR_IVAR, rb_ull2inum(Box::into_raw(recorder) as u64));
    obj
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
    rb_ivar_set(self_val, PTR_IVAR, rb_ull2inum(0));
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
        PTR_IVAR = rb_intern(b"@ptr\0".as_ptr() as *const c_char);
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
