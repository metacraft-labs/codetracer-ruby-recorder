#![allow(clippy::missing_safety_doc)]

use std::sync::Mutex;
use std::{
    ffi::CStr,
    mem::transmute,
    os::raw::{c_char, c_int, c_long, c_void},
    path::Path,
    ptr,
    string::FromUtf8Error,
};

use codetracer_trace_types::{
    EventLogKind, FullValueRecord, Line, TypeId, TypeKind, ValueRecord, NONE_TYPE_ID,
};
use codetracer_trace_writer_nim::{
    create_trace_writer, read_span_stream_json, trace_writer::TraceWriter, NimTraceReaderHandle,
    SpanRecord, StreamingValueEncoder, TraceEventsFileFormat, SPAN_STATUS_ERROR,
};
use rb_sys::{
    rb_add_event_hook2, rb_ary_entry, rb_cArray, rb_cObject, rb_cRange, rb_cRegexp, rb_cStruct,
    rb_cThread, rb_cTime, rb_check_typeddata, rb_const_defined, rb_const_get,
    rb_data_type_struct__bindgen_ty_1, rb_data_type_t, rb_data_typed_object_wrap,
    rb_define_alloc_func, rb_define_class, rb_define_method, rb_define_singleton_method,
    rb_eIOError, rb_eval_string, rb_event_flag_t, rb_event_hook_flag_t, rb_event_hook_func_t,
    rb_funcall, rb_hash_aref, rb_id2name, rb_id2sym, rb_intern, rb_intern2, rb_method_boundp,
    rb_num2dbl, rb_num2long, rb_num2ull, rb_obj_classname, rb_obj_is_kind_of, rb_protect, rb_raise,
    rb_remove_event_hook_with_data, rb_set_errinfo, rb_string_value_cstr, rb_sym2id,
    rb_thread_current, rb_trace_arg_t, rb_tracearg_binding, rb_tracearg_callee_id,
    rb_tracearg_event_flag, rb_tracearg_lineno, rb_tracearg_path, rb_tracearg_raised_exception,
    rb_tracearg_return_value, rb_tracearg_self, rb_ull2inum, rb_utf8_str_new, Qfalse, Qnil, Qtrue,
    ID, NIL_P, RARRAY_LEN, RB_FLOAT_TYPE_P, RB_INTEGER_TYPE_P, RB_SYMBOL_P, RB_TYPE_P,
    RUBY_EVENT_CALL, RUBY_EVENT_LINE, RUBY_EVENT_RAISE, RUBY_EVENT_RETURN, VALUE,
};

type RubyEventHook = unsafe extern "C" fn(rb_event_flag_t, VALUE, VALUE, ID, VALUE);
type RubyMethod = unsafe extern "C" fn() -> VALUE;

unsafe fn ruby_array_entry(array: VALUE, index: usize) -> VALUE {
    rb_ary_entry(array, index as c_long)
}

#[cfg(test)]
mod shared_trace_storage_adapter_tests {
    use codetracer_ctfs::trace_storage::{
        ManagedTraceSender, ManagedUploadKind, ManagedUploadObject, ManagedUploadReceipt,
        SenderError, SenderHealth, SharedSenderBackend, TraceStorageConfig, TRACE_STORAGE_SCHEMA,
    };

    #[test]
    fn ruby_recorder_binds_shared_trace_storage_config() {
        let config = TraceStorageConfig::from_json(include_str!(
            "../../../../../../codetracer-trace-format/codetracer_ctfs/tests/fixtures/trace_storage/storage_config.full.json"
        ))
        .expect("shared trace-storage fixture parses through codetracer_ctfs");

        assert_eq!(config.schema, TRACE_STORAGE_SCHEMA);
        assert_eq!(config.replication.target_replicas, 2);
        assert!(config.shard_policy.enabled);
    }

    #[derive(Default)]
    struct RubyBindingBackend {
        uploaded: Vec<String>,
    }

    impl SharedSenderBackend for RubyBindingBackend {
        fn upload_slice(
            &mut self,
            object: &ManagedUploadObject,
        ) -> Result<ManagedUploadReceipt, SenderError> {
            self.upload(object)
        }

        fn upload_materialized_artifact(
            &mut self,
            object: &ManagedUploadObject,
        ) -> Result<ManagedUploadReceipt, SenderError> {
            self.upload(object)
        }

        fn upload_manifest(
            &mut self,
            object: &ManagedUploadObject,
        ) -> Result<ManagedUploadReceipt, SenderError> {
            self.upload(object)
        }

        fn finalize(
            &mut self,
            _request: &codetracer_ctfs::trace_storage::ManagedFinalizeRequest,
        ) -> Result<(), SenderError> {
            Ok(())
        }

        fn health(&self) -> SenderHealth {
            SenderHealth {
                healthy: true,
                message: "ruby binding backend".to_string(),
            }
        }
    }

    impl RubyBindingBackend {
        fn upload(
            &mut self,
            object: &ManagedUploadObject,
        ) -> Result<ManagedUploadReceipt, SenderError> {
            self.uploaded.push(object.object_key.clone());
            Ok(ManagedUploadReceipt {
                object_key: object.object_key.clone(),
                storage_pool_id: "shared-local".to_string(),
                storage_server_id: "local-storage-1".to_string(),
                storage_endpoint_uri: "local://codetracer-ci/storage-service".to_string(),
            })
        }
    }

    #[test]
    fn ruby_recorder_uses_shared_managed_sender_for_materialized_artifacts() {
        let mut sender = ManagedTraceSender::new(RubyBindingBackend::default(), "ruby-finalize");
        sender
            .upload_materialized_artifact(ManagedUploadObject {
                object_key: "traces/tenant/ruby/materialized-trace-v1.json".to_string(),
                local_path: "/tmp/ruby/materialized-trace-v1.json".to_string(),
                content_length: 256,
                sha256: "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
                    .to_string(),
                kind: ManagedUploadKind::MaterializedArtifact {
                    artifact_kind: "materialized_trace_v1".to_string(),
                },
            })
            .unwrap();
        assert_eq!(sender.backend().uploaded.len(), 1);
    }
}

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
    out_dir: String,
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

unsafe fn should_ignore_receiver(arg: *mut rb_trace_arg_t) -> bool {
    let self_val = rb_tracearg_self(arg);
    if NIL_P(self_val) {
        return false;
    }
    let class_name = cstr_to_string(rb_obj_classname(self_val)).unwrap_or_default();
    class_name == "CodeTracer::RubyRecorder" || class_name == "CodeTracerNativeRecorder"
}

unsafe fn should_ignore_method(arg: *mut rb_trace_arg_t) -> bool {
    let mid = rb_tracearg_callee_id(arg);
    let Some(name) = cstr_to_string(rb_id2name(rb_sym2id(mid))) else {
        return false;
    };
    matches!(
        name.as_str(),
        "start" | "stop" | "flush_trace" | "record_event" | "enable_tracing" | "disable_tracing"
    )
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
            &[],
            TraceEventsFileFormat::Ctfs,
        )),
        data: RecorderData {
            active: false,
            in_event_hook: false,
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
        out_dir: String::new(),
        streaming_encoder: StreamingValueEncoder::new(),
    });
    let ty = std::ptr::addr_of!(RECORDER_TYPE) as *const rb_data_type_t;
    rb_data_typed_object_wrap(klass, Box::into_raw(recorder) as *mut c_void, ty)
}

unsafe extern "C" fn enable_tracing(self_val: VALUE) -> VALUE {
    let recorder = &mut *get_recorder(self_val);
    if !recorder.data.active {
        // Ruby documents internal thread-event callbacks as running without
        // the GVL for most events. The recorder writes through the Nim trace
        // writer, so thread lifecycle events are recorded from the regular
        // Ruby event hook below, where the GVL and recorder invariants hold.

        let raw_cb: unsafe extern "C" fn(VALUE, *mut rb_trace_arg_t) = event_hook_raw;
        let func: rb_event_hook_func_t = Some(transmute::<
            unsafe extern "C" fn(VALUE, *mut rb_trace_arg_t),
            RubyEventHook,
        >(raw_cb));
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
        recorder.data.active = false;
        let raw_cb: unsafe extern "C" fn(VALUE, *mut rb_trace_arg_t) = event_hook_raw;
        let func: rb_event_hook_func_t = Some(transmute::<
            unsafe extern "C" fn(VALUE, *mut rb_trace_arg_t),
            RubyEventHook,
        >(raw_cb));
        rb_remove_event_hook_with_data(func, self_val);

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
        TraceWriter::register_return_cbor(&mut **locked_tracer, &[]);
    }
    Qnil.into()
}

// Hard-pinned to the canonical CTFS multi-stream output per
// `codetracer-specs/Recorder-CLI-Conventions.md` §4 (CTFS-only).  The
// recorder no longer accepts a format parameter: the JSON / Binary /
// BinaryV0 dispatch arms have been removed.  `ct print` (shipped with
// codetracer-trace-format-nim) is the canonical way to convert a
// recorded `*.ct` bundle into JSON or human-readable text.
fn begin_trace(dir: &Path) -> Result<Box<dyn TraceWriter>, Box<dyn std::error::Error>> {
    let mut tracer = create_trace_writer("ruby", &[], TraceEventsFileFormat::Ctfs);
    std::fs::create_dir_all(dir)?;
    tracer.set_workdir(dir);
    let events = dir.join("trace.ct");

    TraceWriter::begin_writing_trace_events(&mut *tracer, &events)?;

    Ok(tracer)
}

fn flush_to_dir(tracer: &mut dyn TraceWriter) -> Result<(), Box<dyn std::error::Error>> {
    TraceWriter::finish_writing_trace_events(tracer)?;
    tracer.write_meta_dat("codetracer-ruby-recorder")?;
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
    rstring_checked(val).unwrap_or_default()
}

unsafe fn rstring_checked(val: VALUE) -> Result<String, FromUtf8Error> {
    let mut value = val;
    let ptr = rb_string_value_cstr(&mut value);
    if ptr.is_null() {
        return String::from_utf8(Vec::new());
    }
    String::from_utf8(CStr::from_ptr(ptr).to_bytes().to_vec())
}

unsafe fn rstring_checked_or_empty(val: VALUE) -> String {
    if NIL_P(val) {
        String::default()
    } else {
        rstring_checked(val).unwrap_or_default()
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

unsafe extern "C" fn call_num2long(arg: VALUE) -> VALUE {
    let data = &mut *(arg as *mut (VALUE, i64));
    data.1 = rb_num2long(data.0) as i64;
    Qnil.into()
}

/// A Ruby Integer as an `i64`, or `None` when it does not fit in one.
///
/// `rb_num2long` RAISES `RangeError` for an Integer outside the machine word —
/// `2 ** 70` is enough — and a raise from inside the event hook is not merely a
/// lost value: it `longjmp`s straight out of `event_hook_raw`, past the
/// `MutexGuard` on the tracer, so the recorder's lock is never released and the
/// next `flush_trace` blocks forever.  Recording a program that computes a big
/// integer therefore used to hang it (reproducible with two lines of Ruby and
/// no middleware in sight).  `rb_protect` turns that into a `None` the caller
/// can encode some other way.
unsafe fn ruby_integer_to_i64(val: VALUE) -> Option<i64> {
    let mut state: c_int = 0;
    let mut data = (val, 0i64);
    rb_protect(
        Some(call_num2long),
        &mut data as *mut (VALUE, i64) as VALUE,
        &mut state,
    );
    if state != 0 {
        rb_set_errinfo(Qnil.into());
        None
    } else {
        Some(data.1)
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
    if rb_obj_is_kind_of(val, rb_cArray) != 0 {
        let len = RARRAY_LEN(val) as usize;
        let type_id = TraceWriter::ensure_type_id(tracer, TypeKind::Seq, "Array");
        encoder.begin_sequence(type_id, len);
        for i in 0..len {
            let elem = ruby_array_entry(val, i);
            encode_ruby_value_streaming(recorder, tracer, encoder, elem, depth - 1);
        }
        encoder.end_compound();
        return;
    }
    if RB_INTEGER_TYPE_P(val) {
        match ruby_integer_to_i64(val) {
            Some(i) => encoder.write_int(i, recorder.int_type_id),
            None => {
                // Outside the machine word.  The value stays VISIBLE as its
                // decimal text instead of aborting the recording — see
                // `ruby_integer_to_i64` for what "aborting" used to mean.
                let text = value_to_string_exception_safe(recorder, val);
                let type_id = TraceWriter::ensure_type_id(tracer, TypeKind::Raw, "Integer");
                encoder.write_raw(&text, type_id);
            }
        }
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
    if RB_TYPE_P(val, rb_sys::ruby_value_type::RUBY_T_HASH) {
        let pairs = rb_funcall(val, recorder.id.to_a, 0);
        let len = RARRAY_LEN(pairs) as usize;
        let seq_type_id = TraceWriter::ensure_type_id(tracer, TypeKind::Seq, "Hash");
        encoder.begin_sequence(seq_type_id, len);
        for i in 0..len {
            let pair = ruby_array_entry(pairs, i);
            if !RB_TYPE_P(pair, rb_sys::ruby_value_type::RUBY_T_ARRAY) || RARRAY_LEN(pair) < 2 {
                // Emit none for malformed pairs to preserve element count.
                encoder.write_none(recorder.error_type_id);
                continue;
            }
            let key = ruby_array_entry(pair, 0);
            let val_elem = ruby_array_entry(pair, 1);
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
    if NIL_P(recorder.set_class) && rb_const_defined(rb_cObject, recorder.id.set_const) != 0 {
        recorder.set_class = rb_const_get(rb_cObject, recorder.id.set_const);
    }
    if !NIL_P(recorder.set_class) && rb_obj_is_kind_of(val, recorder.set_class) != 0 {
        let arr = rb_funcall(val, recorder.id.to_a, 0);
        if RB_TYPE_P(arr, rb_sys::ruby_value_type::RUBY_T_ARRAY) {
            let len = RARRAY_LEN(arr) as usize;
            let type_id = TraceWriter::ensure_type_id(tracer, TypeKind::Seq, "Set");
            encoder.begin_sequence(type_id, len);
            for i in 0..len {
                let elem = ruby_array_entry(arr, i);
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
        let type_id = TraceWriter::ensure_type_id(tracer, TypeKind::Tuple, &class_name);
        encoder.begin_tuple(type_id, len);
        for i in 0..len {
            let value = ruby_array_entry(values, i);
            encode_ruby_value_streaming(recorder, tracer, encoder, value, depth - 1);
        }
        encoder.end_compound();
        return;
    }
    if NIL_P(recorder.open_struct_class)
        && rb_const_defined(rb_cObject, recorder.id.open_struct_const) != 0
    {
        recorder.open_struct_class = rb_const_get(rb_cObject, recorder.id.open_struct_const);
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
    if len > 0 {
        let type_id = TraceWriter::ensure_type_id(tracer, TypeKind::Tuple, &class_name);
        encoder.begin_tuple(type_id, len);
        for i in 0..len {
            let sym = ruby_array_entry(ivars, i);
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
        if std::env::var_os("CODETRACER_RUBY_RECORDER_DEBUG").is_some() {
            eprintln!("codetracer-ruby-recorder: local_variables returned a non-array");
        }
        return;
    }
    let len = RARRAY_LEN(vars) as usize;
    if std::env::var_os("CODETRACER_RUBY_RECORDER_DEBUG").is_some() {
        eprintln!("codetracer-ruby-recorder: recording {len} local variables");
    }
    for i in 0..len {
        let sym = ruby_array_entry(vars, i);
        let name = cstr_to_string(rb_id2name(rb_sym2id(sym))).unwrap_or_default();
        let value = rb_funcall(binding, recorder.id.local_variable_get, 1, sym);
        if std::env::var_os("CODETRACER_RUBY_RECORDER_DEBUG").is_some() {
            eprintln!("codetracer-ruby-recorder: local {name}");
        }
        let cbor = encode_ruby_value_to_cbor(recorder, tracer, encoder, value);
        if std::env::var_os("CODETRACER_RUBY_RECORDER_DEBUG").is_some() {
            eprintln!(
                "codetracer-ruby-recorder: register local {name} cbor_len={}",
                cbor.len()
            );
        }
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
    let mut result = Vec::with_capacity(params_len);
    for i in 0..params_len {
        let pair = ruby_array_entry(params_ary, i);
        if !RB_TYPE_P(pair, rb_sys::ruby_value_type::RUBY_T_ARRAY) || RARRAY_LEN(pair) < 2 {
            continue;
        }
        let name_sym = ruby_array_entry(pair, 1);
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

    // CTFS-only per `Recorder-CLI-Conventions.md` §4.  The second
    // positional argument is preserved for backward FFI compatibility
    // (Ruby's `rb_define_method` registered this method with arity 2)
    // but only `:ctfs` / `:ct` are accepted.  Any other format symbol
    // raises a clear error so callers cannot silently ask for JSON or
    // binary and believe they got it.  Use `ct print` (shipped with
    // codetracer-trace-format-nim) to convert the produced *.ct bundle
    // into JSON or human-readable text.
    if !NIL_P(format) && RB_SYMBOL_P(format) {
        let name = cstr_to_string(rb_id2name(rb_sym2id(format))).unwrap_or_default();
        match name.as_str() {
            "ctfs" | "ct" => {}
            _ => rb_raise(
                rb_eIOError,
                c"codetracer-ruby-recorder is CTFS-only; use `ct print` to convert the trace."
                    .as_ptr() as *const c_char,
            ),
        }
    }

    match rstring_checked(out_dir) {
        Ok(path_str) => {
            match begin_trace(Path::new(&path_str)) {
                Ok(t) => {
                    recorder.tracer = Mutex::new(t);
                    recorder.out_dir = path_str;
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
    if std::env::var("CODETRACER_MANAGED_UPLOAD_URL")
        .ok()
        .filter(|value| !value.trim().is_empty())
        .is_some()
    {
        if let Err(e) = codetracer_ctfs::trace_storage::upload_materialized_artifacts_from_env(
            Path::new(&recorder.out_dir),
            "ruby",
        ) {
            let msg = std::ffi::CString::new(e.message)
                .unwrap_or_else(|_| std::ffi::CString::new("managed upload failed").unwrap());
            rb_raise(
                rb_eIOError,
                c"Failed to upload materialized trace: %s".as_ptr() as *const c_char,
                msg.as_ptr(),
            );
        }
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
    if ((ev & RUBY_EVENT_CALL) != 0 || (ev & RUBY_EVENT_RETURN) != 0) && should_ignore_method(arg) {
        recorder.data.in_event_hook = false;
        return;
    }
    let path_val = rb_tracearg_path(arg);
    let line_val = rb_tracearg_lineno(arg);
    let path = rstring_checked_or_empty(path_val);
    let line = rb_num2long(line_val) as i64;
    if should_ignore_path(&path) || should_ignore_receiver(arg) {
        recorder.data.in_event_hook = false;
        return;
    }

    let thread_id: u64 = rb_eval_string(c"Thread.current".as_ptr() as *const c_char);
    let thread_changed = if let Some(last_thread_id) = recorder.data.last_thread_id {
        last_thread_id != thread_id
    } else {
        true
    };
    if thread_changed {
        // Use the dedicated `register_thread_switch` entry point: the previous
        // `TraceWriter::add_event(TraceLowLevelEvent::ThreadSwitch(...))` call
        // dispatched into a silent no-op on the Nim multi-stream backend, so
        // every thread-switch was lost.  See codetracer-trace-format-nim's
        // `registerThreadSwitch` proc for the multi-stream lowering, and the
        // headless Rust tests in
        // `codetracer-trace-format/codetracer_trace_writer_nim/tests/thread_events.rs`
        // for the round-trip verification.
        TraceWriter::register_thread_switch(&mut **locked_tracer, thread_id);
        recorder.data.last_thread_id = Some(thread_id);
    }

    // Borrow the streaming encoder alongside the tracer. The encoder lives
    // on `Recorder` (outside the Mutex), so there is no aliasing conflict.
    let encoder = &mut recorder.streaming_encoder;

    if (ev & RUBY_EVENT_LINE) != 0 {
        let binding = rb_tracearg_binding(arg);
        if std::env::var_os("CODETRACER_RUBY_RECORDER_DEBUG").is_some() {
            eprintln!(
                "codetracer-ruby-recorder: LINE {path}:{line} binding={}",
                if NIL_P(binding) { "nil" } else { "present" }
            );
        }
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

// ---------------------------------------------------------------------------
// Request / interval spans (RS-M6)
// ---------------------------------------------------------------------------
//
// A *span* is a bounded, labeled interval of execution — an HTTP request, a
// process, a test — appended to the container's `spans.dat` stream (spec:
// `codetracer-specs/Trace-Files/CTFS-Request-Span-Streams.md`).  These three
// entry points are what `CodeTracer::Rack::Middleware` calls instead of writing
// a `codetracer_spans.jsonl` sidecar, so a recorded request becomes a
// *(process, thread, step range)* coordinate INSIDE the very container the
// recorder is writing — which is what lets the Request Panel seek from a
// request row into that request's handler.
//
// They are deliberately thin: span *identity* and the request-shaped policy
// (which metadata keys, in which order, what counts as an error) live in Ruby,
// in `CodeTracer::Native` and the Rack middleware.  Only the two things Ruby
// cannot do — read the writer's step counter and append a record — are here.
//
// The `codetracer-rack` gem never calls these directly; it goes through the
// `CodeTracer::Native` facade, which is a no-op when no recording is active.

/// Intern a Ruby symbol from a runtime string.
///
/// `rb_intern!` only accepts literals, and these keys are looked up from a
/// table, so the runtime form (`rb_intern2`) is used instead.
unsafe fn ruby_symbol(name: &str) -> VALUE {
    rb_id2sym(rb_intern2(
        name.as_ptr() as *const c_char,
        name.len() as c_long,
    ))
}

/// `spec[:key]`, or `nil` when absent.
unsafe fn spec_value(spec: VALUE, key: &str) -> VALUE {
    rb_hash_aref(spec, ruby_symbol(key))
}

/// `spec[:key]` as an unsigned integer; absent / nil is 0.
///
/// 0 is the wire encoding of "unset" for every numeric span field except
/// `span_id` (which the caller validates separately), so conflating nil with
/// zero is exactly right here.
unsafe fn spec_u64(spec: VALUE, key: &str) -> u64 {
    let value = spec_value(spec, key);
    if NIL_P(value) {
        0
    } else {
        rb_num2ull(value) as u64
    }
}

/// `spec[:key]` in Ruby truthiness: only `nil` and `false` are false.
///
/// There is no "default true" here on purpose — `shares_timeline` defaults to
/// true, but that default belongs in the `CodeTracer::Native` facade with the
/// rest of the span policy, not in the FFI shim.
unsafe fn spec_bool(spec: VALUE, key: &str) -> bool {
    let value = spec_value(spec, key);
    !NIL_P(value) && value != (Qfalse as VALUE)
}

/// `spec[:key]` as a String, converting non-strings through `to_s`.
///
/// Uses the exception-safe conversion because a middleware may hand us any
/// object as a metadata value, and a `to_s` that raises must not propagate out
/// of a span registration into the application's request handling.
unsafe fn spec_string(recorder: &RecorderData, spec: VALUE, key: &str) -> String {
    let value = spec_value(spec, key);
    if NIL_P(value) {
        String::new()
    } else {
        value_to_string_exception_safe(recorder, value)
    }
}

/// `spec[:metadata]` as ordered key/value pairs.
///
/// Metadata arrives as an Array of two-element Arrays and never as a Hash:
/// metadata ORDER is part of the wire contract (consumers render the keys in
/// emission order), and while Ruby hashes happen to preserve insertion order,
/// making the ordering explicit in the type is what keeps a future refactor
/// from silently reordering the panel's columns.
unsafe fn spec_metadata(recorder: &RecorderData, spec: VALUE) -> Vec<(String, String)> {
    let array = spec_value(spec, "metadata");
    if NIL_P(array) || !RB_TYPE_P(array, rb_sys::ruby_value_type::RUBY_T_ARRAY) {
        return Vec::new();
    }
    let len = RARRAY_LEN(array) as usize;
    let mut pairs = Vec::with_capacity(len);
    for i in 0..len {
        let pair = ruby_array_entry(array, i);
        if !RB_TYPE_P(pair, rb_sys::ruby_value_type::RUBY_T_ARRAY) || RARRAY_LEN(pair) < 2 {
            continue;
        }
        let key = value_to_string_exception_safe(recorder, ruby_array_entry(pair, 0));
        let value = value_to_string_exception_safe(recorder, ruby_array_entry(pair, 1));
        pairs.push((key, value));
    }
    pairs
}

/// Raise a Ruby `IOError` carrying `message`.
///
/// `rb_raise` never returns (it `longjmp`s), so every caller must have released
/// any `MutexGuard` first: an unwinding-free non-local exit skips destructors,
/// and a still-held tracer lock would wedge every later event-hook callback.
unsafe fn raise_io_error(message: &str) -> ! {
    let text = std::ffi::CString::new(message)
        .unwrap_or_else(|_| std::ffi::CString::new("codetracer: unknown error").unwrap());
    // `rb_raise` is declared diverging in the bindings, which is why this
    // function can be `-> !` with no trailing expression.
    rb_raise(rb_eIOError, c"%s".as_ptr() as *const c_char, text.as_ptr())
}

/// The exec-stream index the NEXT recorded event will occupy — the `start_step`
/// a span opened right now must carry.
///
/// This MUST come from the writer and must never be a recorder-side count of
/// `register_step` calls.  `MultiStreamTraceWriter.stepCount` advances for every
/// exec-stream event — absolute steps, column deltas, raise / catch, thread
/// start / exit / switch — and that counter IS the step id readers walk (a
/// span's `start_step`, the Request Panel's `startGeid`).  This recorder emits
/// a thread-switch event on the first event of every thread, so a self-counted
/// index would already be wrong for the very first request.
unsafe extern "C" fn next_step_index(self_val: VALUE) -> VALUE {
    let recorder = &mut *get_recorder(self_val);
    // The tracer lock is also taken by the event hook.  Setting the re-entrancy
    // flag makes the hook return BEFORE it tries to lock, so a Ruby-level event
    // fired from inside this call cannot deadlock against us.
    let was_in_hook = recorder.data.in_event_hook;
    recorder.data.in_event_hook = true;
    let index = {
        let locked_tracer = recorder.tracer.lock().unwrap();
        TraceWriter::next_step_index(&**locked_tracer)
    };
    recorder.data.in_event_hook = was_in_hook;
    rb_ull2inum(index)
}

/// The thread id THIS RECORDER uses for the calling thread.
///
/// Not `Thread#object_id` and not an OS tid: the event hook identifies threads
/// by the `VALUE` of `Thread.current` and emits `register_thread_switch` with
/// exactly that number, so a span whose `thread_id` came from anywhere else
/// would name a thread the container has never heard of.  Reading it here is
/// what makes a span's thread coordinate resolvable against the recording's own
/// thread events.
unsafe extern "C" fn current_thread_id(_self_val: VALUE) -> VALUE {
    // `rb_thread_current()` is what `Thread.current` evaluates to, which is the
    // expression `event_hook_raw` uses for the same purpose.
    rb_ull2inum(rb_thread_current())
}

/// Append one span record to the recording's span stream.
///
/// `spec` is a Hash with symbol keys mirroring the wire record; see
/// `CodeTracer::Native.register_span`, which owns the defaults.  Returns `true`
/// on success and raises `IOError` when the writer refuses the record — a
/// middleware that believes it recorded a request must never be told it
/// succeeded when nothing was stored.
unsafe extern "C" fn register_span_api(self_val: VALUE, spec: VALUE) -> VALUE {
    let recorder = &mut *get_recorder(self_val);

    if !RB_TYPE_P(spec, rb_sys::ruby_value_type::RUBY_T_HASH) {
        raise_io_error("register_span expects a Hash with symbol keys");
    }

    let was_in_hook = recorder.data.in_event_hook;
    recorder.data.in_event_hook = true;

    // Every Ruby->Rust conversion happens BEFORE the tracer lock is taken:
    // `value_to_string_exception_safe` can call back into Ruby (`to_s`), and
    // Ruby code running while we hold the lock would re-enter the event hook.
    let span_id = spec_u64(spec, "span_id");
    let status = spec_u64(spec, "status");
    let is_open = spec_bool(spec, "is_open");
    let span = SpanRecord {
        span_id,
        parent_span_id: spec_u64(spec, "parent_span_id"),
        is_open,
        // Ruby emits INLINE spans only: the steps are in this very container.
        // The external binding exists for recorders that must write a separate
        // container per request (PHP-FPM), which this one never does.
        is_external: false,
        status: status as u8,
        start_wall_ns: spec_u64(spec, "start_wall_ns"),
        end_wall_ns: if is_open {
            0
        } else {
            spec_u64(spec, "end_wall_ns")
        },
        process_ord: spec_u64(spec, "process_ord"),
        thread_id: spec_u64(spec, "thread_id"),
        start_step: spec_u64(spec, "start_step"),
        end_step: if is_open {
            0
        } else {
            spec_u64(spec, "end_step")
        },
        external_recording: String::new(),
        external_path: String::new(),
        span_type: spec_string(&recorder.data, spec, "span_type"),
        label: spec_string(&recorder.data, spec, "label"),
        contiguous_on_one_thread: spec_bool(spec, "contiguous_on_one_thread"),
        shares_timeline: spec_bool(spec, "shares_timeline"),
        concurrent_with_siblings: spec_bool(spec, "concurrent_with_siblings"),
        metadata: spec_metadata(&recorder.data, spec),
    };

    // Validate before touching the writer so a bad record fails loudly rather
    // than being half-written.
    let validation = if span_id == 0 {
        Some("span_id must be >= 1 (0 is the wire encoding of \"no span\")".to_string())
    } else if status > u64::from(SPAN_STATUS_ERROR) {
        Some(format!(
            "invalid span status {status}; expected 0 (unknown), 1 (ok) or 2 (error)"
        ))
    } else {
        None
    };

    let outcome = if validation.is_some() {
        validation
    } else {
        let mut locked_tracer = recorder.tracer.lock().unwrap();
        match TraceWriter::register_span(&mut **locked_tracer, &span) {
            Ok(()) => None,
            Err(e) => Some(format!("failed to record span: {e}")),
        }
    };

    recorder.data.in_event_hook = was_in_hook;
    match outcome {
        // Raised only after the guard above has been dropped — see
        // `raise_io_error`.
        Some(message) => raise_io_error(&message),
        None => Qtrue.into(),
    }
}

/// Decode the span stream of the `.ct` container at `path` into JSON.
///
/// The READ counterpart of [`register_span_api`], present so this recorder's own
/// integration tests assert on the spans they wrote through the CANONICAL Nim
/// decoder (`initSpanStreamReader`, the same one `ct print -f http` uses) rather
/// than through a second, test-only decoder that could agree with a writer bug.
///
/// A singleton method rather than an instance method: reading a container is not
/// an operation on a live recording, and a test process that only wants to
/// inspect a `.ct` file must not have to start one.
///
/// `settled` applies last-record-wins per `span_id` and sorts ascending by
/// `span_id` (what a panel displays); a false `settled` returns every record in
/// append order, open records included.
unsafe extern "C" fn span_stream_json(_klass: VALUE, path: VALUE, settled: VALUE) -> VALUE {
    let path_string = rstring_checked_or_empty(path);
    let want_settled = !NIL_P(settled) && settled != (Qfalse as VALUE);
    match read_span_stream_json(Path::new(&path_string), want_settled) {
        Ok(json) => rb_utf8_str_new(json.as_ptr() as *const c_char, json.len() as c_long),
        Err(e) => raise_io_error(&format!(
            "failed to read the span stream of {path_string}: {e}"
        )),
    }
}

/// The number of steps recorded in the `.ct` container at `path`.
///
/// Exposed alongside [`span_stream_json`] so a test can check that a span's
/// `[start_step, end_step]` really is a coordinate INSIDE that container — the
/// property that distinguishes an inline-bound span from the sidecar rows it
/// replaces.  Read through the canonical Nim reader.
unsafe extern "C" fn trace_step_count(_klass: VALUE, path: VALUE) -> VALUE {
    let path_string = rstring_checked_or_empty(path);
    match NimTraceReaderHandle::open(&path_string) {
        Ok(reader) => rb_ull2inum(reader.step_count()),
        Err(e) => raise_io_error(&format!("failed to open {path_string}: {e}")),
    }
}

unsafe fn ruby_method(func: *const ()) -> Option<RubyMethod> {
    Some(transmute::<*const (), RubyMethod>(func))
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
            ruby_method(initialize as *const ()),
            2,
        );
        rb_define_method(
            class,
            c"enable_tracing".as_ptr() as *const c_char,
            ruby_method(enable_tracing as *const ()),
            0,
        );
        rb_define_method(
            class,
            c"disable_tracing".as_ptr() as *const c_char,
            ruby_method(disable_tracing as *const ()),
            0,
        );
        rb_define_method(
            class,
            c"flush_trace".as_ptr() as *const c_char,
            ruby_method(flush_trace as *const ()),
            0,
        );
        rb_define_method(
            class,
            c"record_event".as_ptr() as *const c_char,
            ruby_method(record_event_api as *const ()),
            3,
        );
        // RS-M6 span emission.  See the "Request / interval spans" section
        // above; `CodeTracer::Native` is the Ruby-side facade over these.
        rb_define_method(
            class,
            c"next_step_index".as_ptr() as *const c_char,
            ruby_method(next_step_index as *const ()),
            0,
        );
        rb_define_method(
            class,
            c"register_span".as_ptr() as *const c_char,
            ruby_method(register_span_api as *const ()),
            1,
        );
        rb_define_method(
            class,
            c"current_thread_id".as_ptr() as *const c_char,
            ruby_method(current_thread_id as *const ()),
            0,
        );
        // Read side — singleton methods, because inspecting a finished
        // container is not an operation on a live recording.
        rb_define_singleton_method(
            class,
            c"span_stream_json".as_ptr() as *const c_char,
            ruby_method(span_stream_json as *const ()),
            2,
        );
        rb_define_singleton_method(
            class,
            c"trace_step_count".as_ptr() as *const c_char,
            ruby_method(trace_step_count as *const ()),
            1,
        );
    }
}
