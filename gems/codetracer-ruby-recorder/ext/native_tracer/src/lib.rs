#![allow(clippy::missing_safety_doc)]

use std::sync::Mutex;
use std::{
    ffi::CStr,
    mem::transmute,
    os::raw::{c_char, c_int, c_void},
    path::Path,
    ptr,
    string::FromUtf8Error,
};

use codetracer_trace_types::{
    EventLogKind, FullValueRecord, Line, ThreadId, TraceLowLevelEvent, TypeId, TypeKind,
    ValueRecord, NONE_TYPE_ID,
};
use codetracer_trace_writer_nim::{
    create_trace_writer, trace_writer::TraceWriter, StreamingValueEncoder, TraceEventsFileFormat,
};
use rb_sys::{
    rb_add_event_hook2, rb_cObject, rb_cRange, rb_cRegexp, rb_cStruct, rb_cThread, rb_cTime,
    rb_check_typeddata, rb_const_defined, rb_const_get, rb_data_type_struct__bindgen_ty_1,
    rb_data_type_t, rb_data_typed_object_wrap, rb_define_alloc_func, rb_define_class,
    rb_define_method, rb_eIOError, rb_eval_string, rb_event_flag_t, rb_event_hook_flag_t,
    rb_event_hook_func_t, rb_funcall, rb_id2name, rb_id2sym, rb_intern,
    rb_internal_thread_add_event_hook, rb_internal_thread_event_data_t, rb_method_boundp,
    rb_num2dbl, rb_num2long, rb_obj_classname, rb_obj_is_kind_of, rb_protect, rb_raise,
    rb_remove_event_hook_with_data, rb_set_errinfo, rb_sym2id, rb_trace_arg_t, rb_tracearg_binding,
    rb_tracearg_callee_id, rb_tracearg_event_flag, rb_tracearg_lineno, rb_tracearg_path,
    rb_tracearg_raised_exception, rb_tracearg_return_value, rb_tracearg_self, Qfalse, Qnil, Qtrue,
    ID, NIL_P, RARRAY_CONST_PTR, RARRAY_LEN, RB_FLOAT_TYPE_P, RB_INTEGER_TYPE_P, RB_SYMBOL_P,
    RB_TYPE_P, RSTRING_LEN, RSTRING_PTR, RUBY_EVENT_CALL, RUBY_EVENT_LINE, RUBY_EVENT_RAISE,
    RUBY_EVENT_RETURN, RUBY_INTERNAL_THREAD_EVENT_EXITED, RUBY_INTERNAL_THREAD_EVENT_READY,
    RUBY_INTERNAL_THREAD_EVENT_RESUMED, RUBY_INTERNAL_THREAD_EVENT_STARTED,
    RUBY_INTERNAL_THREAD_EVENT_SUSPENDED, VALUE,
};

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

struct RecorderData {
    active: bool,
    in_event_hook: bool,
    thread_event_hook_installed: bool,
    last_thread_id: Option<u64>,
    id: InternedSymbols,
    set_class: VALUE,
    open_struct_class: VALUE,
    int_type_id: TypeId,
    float_type_id: TypeId,
    bool_type_id: TypeId,
    string_type_id: TypeId,
    symbol_type_id: TypeId,
    error_type_id: TypeId,
}

struct Recorder {
    tracer: Mutex<Box<dyn TraceWriter>>,
    data: RecorderData,
    /// Reusable streaming CBOR encoder — avoids building intermediate
    /// `ValueRecord` trees when encoding Ruby values.  Reset between
    /// each top-level value encoding.
    streaming_encoder: StreamingValueEncoder,
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

// Legacy tree-based helpers (value_type_id, struct_value, to_value) have been
// removed — the streaming encoder (M59) encodes Ruby values directly to CBOR
// bytes without building intermediate ValueRecord trees.

unsafe extern "C" fn recorder_free(ptr: *mut c_void) {
    if !ptr.is_null() {
        drop(Box::from_raw(ptr as *mut Recorder));
    }
}

static mut RECORDER_TYPE: rb_data_type_t = rb_data_type_t {
    wrap_struct_name: c"Recorder".as_ptr() as *const c_char,
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
            c"Invalid recorder object".as_ptr() as *const c_char,
        );
    }
    ptr as *mut Recorder
}

unsafe extern "C" fn ruby_recorder_alloc(klass: VALUE) -> VALUE {
    let recorder = Box::new(Recorder {
        tracer: Mutex::new(create_trace_writer(
            "ruby",
            &vec![],
            TraceEventsFileFormat::Ctfs,
        )),
        data: RecorderData {
            active: false,
            in_event_hook: false,
            thread_event_hook_installed: false,
            last_thread_id: None,
            id: InternedSymbols::new(),
            set_class: Qnil.into(),
            open_struct_class: Qnil.into(),
            int_type_id: TypeId::default(),
            float_type_id: TypeId::default(),
            bool_type_id: TypeId::default(),
            string_type_id: TypeId::default(),
            symbol_type_id: TypeId::default(),
            error_type_id: TypeId::default(),
        },
        streaming_encoder: StreamingValueEncoder::new(),
    });
    let ty = std::ptr::addr_of!(RECORDER_TYPE) as *const rb_data_type_t;
    rb_data_typed_object_wrap(klass, Box::into_raw(recorder) as *mut c_void, ty)
}

unsafe extern "C" fn enable_tracing(self_val: VALUE) -> VALUE {
    let recorder = &mut *get_recorder(self_val);
    if !recorder.data.active {
        if !recorder.data.thread_event_hook_installed {
            thread_register_callback(recorder);
            recorder.data.thread_event_hook_installed = true;
        }

        let raw_cb: unsafe extern "C" fn(VALUE, *mut rb_trace_arg_t) = event_hook_raw;
        let func: rb_event_hook_func_t = Some(transmute(raw_cb));
        rb_add_event_hook2(
            func,
            RUBY_EVENT_LINE | RUBY_EVENT_CALL | RUBY_EVENT_RETURN | RUBY_EVENT_RAISE,
            self_val,
            rb_event_hook_flag_t::RUBY_EVENT_HOOK_FLAG_RAW_ARG,
        );
        recorder.data.active = true;
    }
    Qnil.into()
}

unsafe extern "C" fn disable_tracing(self_val: VALUE) -> VALUE {
    let recorder = &mut *get_recorder(self_val);
    if recorder.data.active {
        let raw_cb: unsafe extern "C" fn(VALUE, *mut rb_trace_arg_t) = event_hook_raw;
        let func: rb_event_hook_func_t = Some(transmute(raw_cb));
        rb_remove_event_hook_with_data(func, self_val);
        recorder.data.active = false;

        // Close the implicit top-level call opened in `initialize`.
        //
        // The Nim multi-stream call writer pairs `register_call` with
        // `register_return`: the call record is only persisted when its
        // matching return arrives (it stores the entry/exit step range
        // computed from the step counter at call/return time).  Without
        // this closing return, the `<top-level>` call record is never
        // written, leaving steps that occur before the first user call
        // (e.g. class definition steps in rb_sudoku_solver) with no
        // enclosing call entry.  The downstream db-backend's
        // `call_key_for_step` then returns CallKey(-1) for those steps
        // and the calltrace pane renders nothing.
        let mut locked_tracer = recorder.tracer.lock().unwrap();
        TraceWriter::register_return(
            &mut **locked_tracer,
            ValueRecord::None {
                type_id: recorder.data.error_type_id,
            },
        );
    }
    Qnil.into()
}

fn begin_trace(
    dir: &Path,
    format: TraceEventsFileFormat,
) -> Result<Box<dyn TraceWriter>, Box<dyn std::error::Error>> {
    let mut tracer = create_trace_writer("ruby", &vec![], format);
    std::fs::create_dir_all(dir)?;
    let events = match format {
        TraceEventsFileFormat::Json => dir.join("trace.json"),
        TraceEventsFileFormat::Ctfs => dir.join("trace.ct"),
        TraceEventsFileFormat::BinaryV0 | TraceEventsFileFormat::Binary => dir.join("trace.bin"),
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
    // For the CTFS multi-stream backend, `close()` is the step that
    // actually writes the `.ct` container file to disk. Without this
    // call, CTFS traces produce no output files.
    TraceWriter::close(tracer)?;
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

unsafe fn rstring_checked(val: VALUE) -> Result<String, FromUtf8Error> {
    let ptr = RSTRING_PTR(val);
    let len = RSTRING_LEN(val) as usize;
    let slice = std::slice::from_raw_parts(ptr as *const u8, len);
    String::from_utf8(slice.to_vec())
}

unsafe fn rstring_checked_or_empty(val: VALUE) -> String {
    if NIL_P(val) {
        String::default()
    } else {
        rstring_checked(val).unwrap_or(String::default())
    }
}

unsafe extern "C" fn call_to_s(arg: VALUE) -> VALUE {
    let data = &*(arg as *const (VALUE, ID));
    rb_funcall(data.0, data.1, 0)
}

unsafe fn value_to_string_exception_safe(recorder: &RecorderData, val: VALUE) -> String {
    if RB_TYPE_P(val, rb_sys::ruby_value_type::RUBY_T_STRING) {
        rstring_lossy(val)
    } else {
        let mut state: c_int = 0;
        let data = (val, recorder.id.to_s);
        let str_val = rb_protect(Some(call_to_s), &data as *const _ as VALUE, &mut state);
        if state != 0 {
            rb_set_errinfo(Qnil.into());
            String::default()
        } else {
            rstring_lossy(str_val)
        }
    }
}

/// Maximum recursion depth for streaming encoding. Prevents stack overflow
/// from deeply nested Ruby structures and stays within the encoder's
/// compound nesting limit (32 levels).
const MAX_STREAMING_DEPTH: usize = 10;

/// Encode a Ruby `VALUE` directly to CBOR bytes using the streaming encoder,
/// bypassing intermediate `ValueRecord` tree allocation.
///
/// This is the M59 fast path — analogous to the Python M58 streaming encoder.
/// Ruby objects are walked recursively and encoded via `StreamingValueEncoder`
/// C FFI calls.
unsafe fn encode_ruby_value_streaming(
    recorder: &mut RecorderData,
    tracer: &mut dyn TraceWriter,
    encoder: &mut StreamingValueEncoder,
    val: VALUE,
    depth: usize,
) {
    if depth == 0 {
        encoder.write_none(recorder.error_type_id);
        return;
    }
    if NIL_P(val) {
        encoder.write_none(recorder.error_type_id);
        return;
    }
    if val == (Qtrue as VALUE) || val == (Qfalse as VALUE) {
        encoder.write_bool(val == (Qtrue as VALUE), recorder.bool_type_id);
        return;
    }
    if RB_INTEGER_TYPE_P(val) {
        let i = rb_num2long(val) as i64;
        encoder.write_int(i, recorder.int_type_id);
        return;
    }
    if RB_FLOAT_TYPE_P(val) {
        let f = rb_num2dbl(val);
        let type_id = if recorder.float_type_id == NONE_TYPE_ID {
            let id = TraceWriter::ensure_type_id(tracer, TypeKind::Float, "Float");
            recorder.float_type_id = id;
            id
        } else {
            recorder.float_type_id
        };
        encoder.write_float(f, type_id);
        return;
    }
    if RB_SYMBOL_P(val) {
        let text = cstr_to_string(rb_id2name(rb_sym2id(val))).unwrap_or_default();
        encoder.write_string(&text, recorder.symbol_type_id);
        return;
    }
    if RB_TYPE_P(val, rb_sys::ruby_value_type::RUBY_T_STRING) {
        let text = rstring_lossy(val);
        encoder.write_string(&text, recorder.string_type_id);
        return;
    }
    if RB_TYPE_P(val, rb_sys::ruby_value_type::RUBY_T_ARRAY) {
        let len = RARRAY_LEN(val) as usize;
        let type_id = TraceWriter::ensure_type_id(tracer, TypeKind::Seq, "Array");
        encoder.begin_sequence(type_id, len);
        let ptr = RARRAY_CONST_PTR(val);
        for i in 0..len {
            let elem = *ptr.add(i);
            encode_ruby_value_streaming(recorder, tracer, encoder, elem, depth - 1);
        }
        encoder.end_compound();
        return;
    }
    if RB_TYPE_P(val, rb_sys::ruby_value_type::RUBY_T_HASH) {
        let pairs = rb_funcall(val, recorder.id.to_a, 0);
        let len = RARRAY_LEN(pairs) as usize;
        let ptr = RARRAY_CONST_PTR(pairs);
        let seq_type_id = TraceWriter::ensure_type_id(tracer, TypeKind::Seq, "Hash");
        encoder.begin_sequence(seq_type_id, len);
        for i in 0..len {
            let pair = *ptr.add(i);
            if !RB_TYPE_P(pair, rb_sys::ruby_value_type::RUBY_T_ARRAY) || RARRAY_LEN(pair) < 2 {
                // Emit none for malformed pairs to preserve element count.
                encoder.write_none(recorder.error_type_id);
                continue;
            }
            let pair_ptr = RARRAY_CONST_PTR(pair);
            let key = *pair_ptr.add(0);
            let val_elem = *pair_ptr.add(1);
            // Encode each pair as a 2-element tuple with fields "k" and "v",
            // matching the struct_value("Pair", ...) encoding in the legacy path.
            let pair_type_id = TraceWriter::ensure_type_id(tracer, TypeKind::Tuple, "Pair");
            encoder.begin_tuple(pair_type_id, 2);
            encode_ruby_value_streaming(recorder, tracer, encoder, key, depth - 1);
            encode_ruby_value_streaming(recorder, tracer, encoder, val_elem, depth - 1);
            encoder.end_compound();
        }
        encoder.end_compound();
        return;
    }
    if rb_obj_is_kind_of(val, rb_cThread) != 0 {
        let type_id = TraceWriter::ensure_type_id(tracer, TypeKind::Tuple, "Thread");
        encoder.begin_tuple(type_id, 0);
        encoder.end_compound();
        return;
    }
    if rb_obj_is_kind_of(val, rb_cRange) != 0 {
        let begin_val = rb_funcall(val, recorder.id.begin, 0);
        let end_val = rb_funcall(val, recorder.id.end, 0);
        let type_id = TraceWriter::ensure_type_id(tracer, TypeKind::Tuple, "Range");
        encoder.begin_tuple(type_id, 2);
        encode_ruby_value_streaming(recorder, tracer, encoder, begin_val, depth - 1);
        encode_ruby_value_streaming(recorder, tracer, encoder, end_val, depth - 1);
        encoder.end_compound();
        return;
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
            let type_id = TraceWriter::ensure_type_id(tracer, TypeKind::Seq, "Set");
            encoder.begin_sequence(type_id, len);
            for i in 0..len {
                let elem = *ptr.add(i);
                encode_ruby_value_streaming(recorder, tracer, encoder, elem, depth - 1);
            }
            encoder.end_compound();
            return;
        }
    }
    if rb_obj_is_kind_of(val, rb_cTime) != 0 {
        let sec = rb_funcall(val, recorder.id.to_i, 0);
        let nsec = rb_funcall(val, recorder.id.nsec, 0);
        let type_id = TraceWriter::ensure_type_id(tracer, TypeKind::Tuple, "Time");
        encoder.begin_tuple(type_id, 2);
        encode_ruby_value_streaming(recorder, tracer, encoder, sec, depth - 1);
        encode_ruby_value_streaming(recorder, tracer, encoder, nsec, depth - 1);
        encoder.end_compound();
        return;
    }
    if rb_obj_is_kind_of(val, rb_cRegexp) != 0 {
        let src = rb_funcall(val, recorder.id.source, 0);
        let opts = rb_funcall(val, recorder.id.options, 0);
        let type_id = TraceWriter::ensure_type_id(tracer, TypeKind::Tuple, "Regexp");
        encoder.begin_tuple(type_id, 2);
        encode_ruby_value_streaming(recorder, tracer, encoder, src, depth - 1);
        encode_ruby_value_streaming(recorder, tracer, encoder, opts, depth - 1);
        encoder.end_compound();
        return;
    }
    if rb_obj_is_kind_of(val, rb_cStruct) != 0 {
        let class_name =
            cstr_to_string(rb_obj_classname(val)).unwrap_or_else(|| "Struct".to_string());
        let members = rb_funcall(val, recorder.id.members, 0);
        let values = rb_funcall(val, recorder.id.values, 0);
        if !RB_TYPE_P(members, rb_sys::ruby_value_type::RUBY_T_ARRAY)
            || !RB_TYPE_P(values, rb_sys::ruby_value_type::RUBY_T_ARRAY)
        {
            let text = value_to_string_exception_safe(recorder, val);
            let type_id = TraceWriter::ensure_type_id(tracer, TypeKind::Raw, &class_name);
            encoder.write_raw(&text, type_id);
            return;
        }
        let len = RARRAY_LEN(values) as usize;
        let val_ptr = RARRAY_CONST_PTR(values);
        let type_id = TraceWriter::ensure_type_id(tracer, TypeKind::Tuple, &class_name);
        encoder.begin_tuple(type_id, len);
        for i in 0..len {
            encode_ruby_value_streaming(recorder, tracer, encoder, *val_ptr.add(i), depth - 1);
        }
        encoder.end_compound();
        return;
    }
    if NIL_P(recorder.open_struct_class) {
        if rb_const_defined(rb_cObject, recorder.id.open_struct_const) != 0 {
            recorder.open_struct_class = rb_const_get(rb_cObject, recorder.id.open_struct_const);
        }
    }
    if !NIL_P(recorder.open_struct_class) && rb_obj_is_kind_of(val, recorder.open_struct_class) != 0
    {
        let h = rb_funcall(val, recorder.id.to_h, 0);
        encode_ruby_value_streaming(recorder, tracer, encoder, h, depth - 1);
        return;
    }
    let class_name = cstr_to_string(rb_obj_classname(val)).unwrap_or_else(|| "Object".to_string());
    // Generic object: encode instance variables as a tuple.
    let ivars = rb_funcall(val, recorder.id.instance_variables, 0);
    if !RB_TYPE_P(ivars, rb_sys::ruby_value_type::RUBY_T_ARRAY) {
        let text = value_to_string_exception_safe(recorder, val);
        let type_id = TraceWriter::ensure_type_id(tracer, TypeKind::Raw, &class_name);
        encoder.write_raw(&text, type_id);
        return;
    }
    let len = RARRAY_LEN(ivars) as usize;
    let ptr = RARRAY_CONST_PTR(ivars);
    if len > 0 {
        let type_id = TraceWriter::ensure_type_id(tracer, TypeKind::Tuple, &class_name);
        encoder.begin_tuple(type_id, len);
        for i in 0..len {
            let sym = *ptr.add(i);
            let value = rb_funcall(val, recorder.id.instance_variable_get, 1, sym);
            encode_ruby_value_streaming(recorder, tracer, encoder, value, depth - 1);
        }
        encoder.end_compound();
        return;
    }
    let text = value_to_string_exception_safe(recorder, val);
    let type_id = TraceWriter::ensure_type_id(tracer, TypeKind::Raw, &class_name);
    encoder.write_raw(&text, type_id);
}

/// Encode a single Ruby value to CBOR bytes, resetting the encoder first.
/// Returns a copy of the CBOR bytes suitable for passing to
/// `register_variable_cbor` or `register_return_cbor`.
unsafe fn encode_ruby_value_to_cbor(
    recorder: &mut RecorderData,
    tracer: &mut dyn TraceWriter,
    encoder: &mut StreamingValueEncoder,
    val: VALUE,
) -> Vec<u8> {
    encoder.reset();
    encode_ruby_value_streaming(recorder, tracer, encoder, val, MAX_STREAMING_DEPTH);
    encoder.get_bytes_copy()
}

/// Streaming variant of `record_variables`. Encodes Ruby local variables
/// directly to CBOR bytes and registers them via `register_variable_cbor`,
/// avoiding intermediate `ValueRecord` tree allocations.
unsafe fn record_variables_streaming(
    recorder: &mut RecorderData,
    tracer: &mut dyn TraceWriter,
    encoder: &mut StreamingValueEncoder,
    binding: VALUE,
) {
    let vars = rb_funcall(binding, recorder.id.local_variables, 0);
    if !RB_TYPE_P(vars, rb_sys::ruby_value_type::RUBY_T_ARRAY) {
        return;
    }
    let len = RARRAY_LEN(vars) as usize;
    let ptr = RARRAY_CONST_PTR(vars);
    for i in 0..len {
        let sym = *ptr.add(i);
        let name = cstr_to_string(rb_id2name(rb_sym2id(sym))).unwrap_or_default();
        let value = rb_funcall(binding, recorder.id.local_variable_get, 1, sym);
        let cbor = encode_ruby_value_to_cbor(recorder, tracer, encoder, value);
        TraceWriter::register_variable_cbor(tracer, &name, &cbor);
    }
}

// Legacy record_variables has been removed — replaced by
// record_variables_streaming (M59).

/// Streaming variant of parameter collection. Encodes each parameter value
/// directly to CBOR bytes using the streaming encoder, registers it via
/// `register_variable_cbor`, and returns (name, variable_id) pairs for
/// constructing `CallRecord.args`.
unsafe fn collect_and_register_params_streaming(
    recorder: &mut RecorderData,
    tracer: &mut dyn TraceWriter,
    encoder: &mut StreamingValueEncoder,
    binding: VALUE,
    defined_class: VALUE,
    mid: ID,
) -> Vec<FullValueRecord> {
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
        if let Some(name) = cstr_to_string(rb_id2name(rb_sym2id(name_sym))) {
            let value = rb_funcall(binding, recorder.id.local_variable_get, 1, name_sym);
            let cbor = encode_ruby_value_to_cbor(recorder, tracer, encoder, value);
            TraceWriter::register_variable_cbor(tracer, &name, &cbor);
            // Stage the same CBOR bytes on the writer's pending-call-args
            // buffer so the next `register_call` attaches them to the
            // call record's `args` field.  Without this the CTFS call
            // record has empty `args` and the frontend's calltrace pane
            // renders calls as `f()` instead of `f(name=value)`.
            TraceWriter::register_call_arg(tracer, &name, &cbor);
            let var_id = TraceWriter::ensure_variable_id(tracer, &name);
            // We still need a ValueRecord for FullValueRecord in CallRecord.args.
            // Use a lightweight None sentinel — the CBOR data is already registered
            // and the reader will use CBOR for the actual value.
            result.push(FullValueRecord {
                variable_id: var_id,
                value: ValueRecord::None {
                    type_id: recorder.error_type_id,
                },
            });
        }
    }
    result
}

// Legacy collect_parameter_values / register_parameter_values have been
// removed — replaced by collect_and_register_params_streaming (M59).

unsafe fn record_event(tracer: &mut dyn TraceWriter, path: &str, line: i64, content: String) {
    TraceWriter::register_step(tracer, Path::new(path), Line(line));
    TraceWriter::register_special_event(tracer, EventLogKind::Write, "", &content)
}

unsafe extern "C" fn initialize(self_val: VALUE, out_dir: VALUE, format: VALUE) -> VALUE {
    let recorder_ptr = get_recorder(self_val);
    let recorder = &mut *recorder_ptr;

    let fmt = if !NIL_P(format) && RB_SYMBOL_P(format) {
        match cstr_to_string(rb_id2name(rb_sym2id(format)))
            .unwrap_or_default()
            .as_str()
        {
            "binaryv0" => TraceEventsFileFormat::BinaryV0,
            "binary" | "bin" => TraceEventsFileFormat::Binary,
            "json" => TraceEventsFileFormat::Json,
            "ctfs" | "ct" => TraceEventsFileFormat::Ctfs,
            _ => rb_raise(rb_eIOError, c"Unknown format".as_ptr() as *const c_char),
        }
    } else {
        TraceEventsFileFormat::Ctfs
    };

    match rstring_checked(out_dir) {
        Ok(path_str) => {
            match begin_trace(Path::new(&path_str), fmt) {
                Ok(t) => {
                    recorder.tracer = Mutex::new(t);
                    let mut locked_tracer = recorder.tracer.lock().unwrap();
                    // pre-register common types to match the pure Ruby tracer
                    recorder.data.int_type_id =
                        TraceWriter::ensure_type_id(&mut **locked_tracer, TypeKind::Int, "Integer");
                    recorder.data.string_type_id = TraceWriter::ensure_type_id(
                        &mut **locked_tracer,
                        TypeKind::String,
                        "String",
                    );
                    recorder.data.bool_type_id =
                        TraceWriter::ensure_type_id(&mut **locked_tracer, TypeKind::Bool, "Bool");
                    recorder.data.float_type_id = NONE_TYPE_ID;
                    recorder.data.symbol_type_id = TraceWriter::ensure_type_id(
                        &mut **locked_tracer,
                        TypeKind::String,
                        "Symbol",
                    );
                    recorder.data.error_type_id = TraceWriter::ensure_type_id(
                        &mut **locked_tracer,
                        TypeKind::Error,
                        "No type",
                    );
                    let path = Path::new("");
                    let func_id = TraceWriter::ensure_function_id(
                        &mut **locked_tracer,
                        "<top-level>",
                        path,
                        Line(1),
                    );
                    // Use register_call (not add_event) — the NimTraceWriter
                    // backing the CTFS multi-stream output silently drops
                    // TraceLowLevelEvent variants since it does not maintain
                    // an in-memory event buffer.  register_call is the
                    // canonical FFI hook that emits the Call record.
                    TraceWriter::register_call(&mut **locked_tracer, func_id, vec![]);
                }
                Err(e) => {
                    let msg = std::ffi::CString::new(e.to_string())
                        .unwrap_or_else(|_| std::ffi::CString::new("unknown error").unwrap());
                    rb_raise(
                        rb_eIOError,
                        c"Failed to flush trace: %s".as_ptr() as *const c_char,
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
                c"Invalid UTF-8 in path: %s".as_ptr() as *const c_char,
                msg.as_ptr(),
            )
        }
    }

    Qnil.into()
}

unsafe extern "C" fn flush_trace(self_val: VALUE) -> VALUE {
    let recorder_ptr = get_recorder(self_val);
    let recorder = &mut *recorder_ptr;
    let mut locked_tracer = recorder.tracer.lock().unwrap();

    if let Err(e) = flush_to_dir(&mut **locked_tracer) {
        let msg = std::ffi::CString::new(e.to_string())
            .unwrap_or_else(|_| std::ffi::CString::new("unknown error").unwrap());
        rb_raise(
            rb_eIOError,
            c"Failed to flush trace: %s".as_ptr() as *const c_char,
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
    if recorder.data.in_event_hook {
        return Qnil.into();
    }
    let mut locked_tracer = recorder.tracer.lock().unwrap();
    let path_string = rstring_checked_or_empty(path);
    let line_num = rb_num2long(line) as i64;
    let content_str = value_to_string_exception_safe(&recorder.data, content);
    record_event(&mut **locked_tracer, &path_string, line_num, content_str);
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
    if !recorder.data.active {
        return;
    }

    if recorder.data.in_event_hook {
        return;
    }
    recorder.data.in_event_hook = true;

    let mut locked_tracer = recorder.tracer.lock().unwrap();

    let ev: rb_event_flag_t = rb_tracearg_event_flag(arg);
    let path_val = rb_tracearg_path(arg);
    let line_val = rb_tracearg_lineno(arg);
    let path = rstring_checked_or_empty(path_val);
    let line = rb_num2long(line_val) as i64;
    if should_ignore_path(&path) {
        recorder.data.in_event_hook = false;
        return;
    }

    let thread_id: u64 = rb_eval_string(c"Thread.current".as_ptr() as *const c_char)
        .try_into()
        .unwrap();
    let thread_changed = if let Some(last_thread_id) = recorder.data.last_thread_id {
        last_thread_id != thread_id
    } else {
        true
    };
    if thread_changed {
        TraceWriter::add_event(
            &mut **locked_tracer,
            TraceLowLevelEvent::ThreadSwitch(ThreadId(thread_id)),
        );
        recorder.data.last_thread_id = Some(thread_id);
    }

    // Borrow the streaming encoder alongside the tracer. The encoder lives
    // on `Recorder` (outside the Mutex), so there is no aliasing conflict.
    let encoder = &mut recorder.streaming_encoder;

    if (ev & RUBY_EVENT_LINE) != 0 {
        let binding = rb_tracearg_binding(arg);
        TraceWriter::register_step(&mut **locked_tracer, Path::new(&path), Line(line));
        if !NIL_P(binding) {
            record_variables_streaming(&mut recorder.data, &mut **locked_tracer, encoder, binding);
        }
    } else if (ev & RUBY_EVENT_CALL) != 0 {
        let binding = rb_tracearg_binding(arg);

        let self_val = rb_tracearg_self(arg);
        let mid_sym = rb_tracearg_callee_id(arg);
        let mid = rb_sym2id(mid_sym);
        let defined_class = rb_funcall(self_val, recorder.data.id.class, 0);

        let param_args = if NIL_P(binding) {
            Vec::new()
        } else {
            collect_and_register_params_streaming(
                &mut recorder.data,
                &mut **locked_tracer,
                encoder,
                binding,
                defined_class,
                mid,
            )
        };

        // Encode `self` via streaming encoder.
        let class_name =
            cstr_to_string(rb_obj_classname(self_val)).unwrap_or_else(|| "Object".to_string());
        let text = value_to_string_exception_safe(&recorder.data, self_val);
        let self_type =
            TraceWriter::ensure_type_id(&mut **locked_tracer, TypeKind::Raw, &class_name);
        encoder.reset();
        encoder.write_raw(&text, self_type);
        let self_cbor = encoder.get_bytes_copy();
        TraceWriter::register_variable_cbor(&mut **locked_tracer, "self", &self_cbor);
        // Also stage `self` as the first call arg so the frontend's
        // calltrace pane can render the receiver alongside the method
        // name (matches the Ruby convention of method calls being
        // dispatched on a receiver).
        TraceWriter::register_call_arg(&mut **locked_tracer, "self", &self_cbor);

        let self_var_id = TraceWriter::ensure_variable_id(&mut **locked_tracer, "self");
        let self_arg = FullValueRecord {
            variable_id: self_var_id,
            value: ValueRecord::None {
                type_id: recorder.data.error_type_id,
            },
        };
        let mut args = vec![self_arg];
        if !param_args.is_empty() {
            args.extend(param_args);
        }
        TraceWriter::register_step(&mut **locked_tracer, Path::new(&path), Line(line));
        let mut name = cstr_to_string(rb_id2name(mid)).unwrap_or_default();
        if class_name != "Object" {
            name = format!("{}#{}", class_name, name);
        }
        let fid = TraceWriter::ensure_function_id(
            &mut **locked_tracer,
            &name,
            Path::new(&path),
            Line(line),
        );
        // Emit the call via register_call (the NimTraceWriter handles args
        // through preceding register_variable_cbor calls — see lines above
        // for `self` and per-parameter registration).  add_event is a no-op
        // for the CTFS multi-stream backend.
        TraceWriter::register_call(&mut **locked_tracer, fid, args);
    } else if (ev & RUBY_EVENT_RETURN) != 0 {
        TraceWriter::register_step(&mut **locked_tracer, Path::new(&path), Line(line));
        let ret = rb_tracearg_return_value(arg);
        let cbor =
            encode_ruby_value_to_cbor(&mut recorder.data, &mut **locked_tracer, encoder, ret);
        TraceWriter::register_variable_cbor(&mut **locked_tracer, "<return_value>", &cbor);
        TraceWriter::register_return_cbor(&mut **locked_tracer, &cbor);
    } else if (ev & RUBY_EVENT_RAISE) != 0 {
        let exc = rb_tracearg_raised_exception(arg);
        let msg = value_to_string_exception_safe(&recorder.data, exc);
        TraceWriter::register_special_event(&mut **locked_tracer, EventLogKind::Error, "", &msg);
    }
    recorder.data.in_event_hook = false;
}

unsafe extern "C" fn ex_callback(
    event: rb_event_flag_t,
    event_data: *const rb_internal_thread_event_data_t,
    user_data: *mut c_void,
) {
    match event {
        RUBY_INTERNAL_THREAD_EVENT_STARTED => {
            let recorder = user_data as *mut Recorder;
            let mut locked_tracer = (*recorder).tracer.lock().unwrap();
            let event = TraceLowLevelEvent::ThreadStart(ThreadId((*event_data).thread));
            TraceWriter::add_event(&mut **locked_tracer, event);
        }
        RUBY_INTERNAL_THREAD_EVENT_EXITED => {
            let recorder = user_data as *mut Recorder;
            let mut locked_tracer = (*recorder).tracer.lock().unwrap();
            let event = TraceLowLevelEvent::ThreadExit(ThreadId((*event_data).thread));
            TraceWriter::add_event(&mut **locked_tracer, event);
        }
        /*RUBY_INTERNAL_THREAD_EVENT_READY => {
            println!("RUBY_INTERNAL_THREAD_EVENT_READY");
        }
        RUBY_INTERNAL_THREAD_EVENT_RESUMED => {
            println!("RUBY_INTERNAL_THREAD_EVENT_RESUMED");
        }
        RUBY_INTERNAL_THREAD_EVENT_SUSPENDED => {
            println!("RUBY_INTERNAL_THREAD_EVENT_SUSPENDED");
        }*/
        _ => {}
    }
}

unsafe fn thread_register_callback(recorder: *mut Recorder) {
    let q = rb_internal_thread_add_event_hook(
        Some(ex_callback),
        RUBY_INTERNAL_THREAD_EVENT_STARTED
            | RUBY_INTERNAL_THREAD_EVENT_READY
            | RUBY_INTERNAL_THREAD_EVENT_RESUMED
            | RUBY_INTERNAL_THREAD_EVENT_SUSPENDED
            | RUBY_INTERNAL_THREAD_EVENT_EXITED,
        recorder as *mut c_void,
    );
}

#[no_mangle]
pub extern "C" fn Init_codetracer_ruby_recorder() {
    unsafe {
        let class = rb_define_class(
            c"CodeTracerNativeRecorder".as_ptr() as *const c_char,
            rb_cObject,
        );
        rb_define_alloc_func(class, Some(ruby_recorder_alloc));

        rb_define_method(
            class,
            c"initialize".as_ptr() as *const c_char,
            Some(std::mem::transmute(initialize as *const ())),
            2,
        );
        rb_define_method(
            class,
            c"enable_tracing".as_ptr() as *const c_char,
            Some(std::mem::transmute(enable_tracing as *const ())),
            0,
        );
        rb_define_method(
            class,
            c"disable_tracing".as_ptr() as *const c_char,
            Some(std::mem::transmute(disable_tracing as *const ())),
            0,
        );
        rb_define_method(
            class,
            c"flush_trace".as_ptr() as *const c_char,
            Some(std::mem::transmute(flush_trace as *const ())),
            0,
        );
        rb_define_method(
            class,
            c"record_event".as_ptr() as *const c_char,
            Some(std::mem::transmute(record_event_api as *const ())),
            3,
        );
    }
}
