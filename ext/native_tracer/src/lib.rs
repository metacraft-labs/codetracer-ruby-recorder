use std::ffi::CStr;
use std::os::raw::{c_char, c_int};
use rb_sys::{VALUE, ID, rb_add_event_hook2, rb_event_flag_t, RUBY_EVENT_LINE, rb_sourcefile, rb_sourceline, RUBY_EVENT_HOOK_FLAG_RAW_ARG};
use runtime_tracing::{TraceWriter, StepRecord};

static mut WRITER: Option<TraceWriter<std::fs::File>> = None;

extern "C" fn event_hook(ev: rb_event_flag_t, _data: VALUE, _self: VALUE, _mid: ID, _klass: VALUE) {
    if ev & RUBY_EVENT_LINE as rb_event_flag_t != 0 {
        unsafe {
            if let Some(writer) = WRITER.as_mut() {
                let line: u32 = rb_sourceline() as u32;
                let file_ptr: *const c_char = rb_sourcefile();
                if !file_ptr.is_null() {
                    if let Ok(path) = CStr::from_ptr(file_ptr).to_str() {
                        let rec = StepRecord { path: path.into(), line };
                        let _ = writer.write_step(&rec);
                    }
                }
            }
        }
    }
}

#[no_mangle]
pub extern "C" fn Init_codetracer_ruby_recorder() {
    unsafe {
        let out = std::env::var("CODETRACER_DB_TRACE_PATH").unwrap_or_else(|_| "trace.json".to_string());
        let file = std::fs::File::create(out).expect("failed to create trace output");
        WRITER = Some(TraceWriter::new(file));
        rb_add_event_hook2(Some(event_hook), RUBY_EVENT_LINE as rb_event_flag_t, 0 as VALUE, RUBY_EVENT_HOOK_FLAG_RAW_ARG as i32);
    }
}
