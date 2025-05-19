#![allow(clippy::missing_safety_doc)]

use std::{ffi::CStr, mem::transmute, os::raw::c_char};

use rb_sys::{
    // frequently used public items
    rb_add_event_hook2, rb_event_flag_t,
    rb_event_hook_flag_t::RUBY_EVENT_HOOK_FLAG_RAW_ARG,
    ID, VALUE, RUBY_EVENT_LINE,

    // the raw-trace-API symbols live in the generated `bindings` module
    bindings::{
        rb_trace_arg_t,             // struct rb_trace_arg
        rb_tracearg_event_flag,     // event kind helpers
        rb_tracearg_lineno,
        rb_tracearg_path,
    },
};

/// Raw-argument callback (Ruby will call it when we set
/// `RUBY_EVENT_HOOK_FLAG_RAW_ARG`).
///
/// C prototype:
/// ```c
/// void (*)(VALUE data, rb_trace_arg_t *arg);
/// ```
unsafe extern "C" fn event_hook_raw(_data: VALUE, arg: *mut rb_trace_arg_t) {
    if arg.is_null() {
        return;
    }

    let ev: rb_event_flag_t = rb_tracearg_event_flag(arg);
    if (ev & RUBY_EVENT_LINE) == 0 {
        return;
    }

    let path_ptr = rb_tracearg_path(arg) as *const c_char;
    let line = rb_tracearg_lineno(arg) as u32;

    if !path_ptr.is_null() {
        if let Ok(path) = CStr::from_ptr(path_ptr).to_str() {
            println!("Path: {path}, Line: {line}");
        }
    }
}

#[no_mangle]
pub extern "C" fn Init_codetracer_ruby_recorder() {
    unsafe {
        // rb_add_event_hook2’s first parameter is a function pointer with the
        // classic five-argument signature.  We cast our raw callback to that
        // type via an intermediate variable so the sizes match.
        let raw_cb: unsafe extern "C" fn(VALUE, *mut rb_trace_arg_t) = event_hook_raw;
        let cb: unsafe extern "C" fn(rb_event_flag_t, VALUE, VALUE, ID, VALUE) =
            transmute(raw_cb);

        rb_add_event_hook2(
            Some(cb),                 // callback (now cast)
            RUBY_EVENT_LINE,          // which events
            0,                        // user data
            RUBY_EVENT_HOOK_FLAG_RAW_ARG,
        );
    }
}
