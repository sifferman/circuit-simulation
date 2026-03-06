#include "circuit_sim.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

#include <algorithm>
#include <cctype>
#include <cstdlib>
#include <filesystem>
#include <fstream>
#include <sstream>
#include <string>
#include <vector>
#include <iomanip>
#include <thread>
#include <chrono>

using namespace godot;
namespace fs = std::filesystem;

namespace {
// Returns a lowercase copy for case-insensitive matching.
std::string to_lower_copy(const std::string &input) {
    std::string out = input;
    std::transform(out.begin(), out.end(), out.begin(), [](unsigned char c) {
        return static_cast<char>(std::tolower(c));
    });
    return out;
}

// Trims leading/trailing ASCII whitespace.
std::string trim_copy(const std::string &input) {
    size_t start = 0;
    while (start < input.size() && std::isspace(static_cast<unsigned char>(input[start]))) {
        start++;
    }

    size_t end = input.size();
    while (end > start && std::isspace(static_cast<unsigned char>(input[end - 1]))) {
        end--;
    }

    return input.substr(start, end - start);
}

// Case-insensitive prefix check.
bool starts_with_ci(const std::string &line, const std::string &prefix) {
    if (line.size() < prefix.size()) {
        return false;
    }
    for (size_t i = 0; i < prefix.size(); i++) {
        if (std::tolower(static_cast<unsigned char>(line[i])) != std::tolower(static_cast<unsigned char>(prefix[i]))) {
            return false;
        }
    }
    return true;
}

// Removes wrapping double quotes when present.
std::string unquote_copy(const std::string &value) {
    if (value.size() >= 2 && value.front() == '"' && value.back() == '"') {
        return value.substr(1, value.size() - 2);
    }
    return value;
}

// Adds wrapping double quotes when requested.
std::string maybe_quote(const std::string &value, bool should_quote) {
    return should_quote ? "\"" + value + "\"" : value;
}

// Replaces all occurrences of a token in a copied string.
std::string replace_all_copy(std::string value, const std::string &needle, const std::string &replacement) {
    size_t pos = 0;
    while ((pos = value.find(needle, pos)) != std::string::npos) {
        value.replace(pos, needle.size(), replacement);
        pos += replacement.size();
    }
    return value;
}

// Expands PDK_ROOT references from argument or environment.
std::string expand_pdk_root(std::string value, const std::string &pdk_root) {
    const char *env_pdk_root = std::getenv("PDK_ROOT");
    const std::string root = pdk_root.empty() ? (env_pdk_root ? std::string(env_pdk_root) : std::string()) : pdk_root;
    if (root.empty()) {
        return value;
    }
    value = replace_all_copy(value, "$PDK_ROOT", root);
    value = replace_all_copy(value, "${PDK_ROOT}", root);
    return value;
}

// Resolves a path token to an absolute normalized path.
std::string resolve_path_token(const std::string &raw_path, const fs::path &base_dir, const std::string &pdk_root) {
    std::string expanded = expand_pdk_root(raw_path, pdk_root);
    if (expanded.empty()) {
        return expanded;
    }

    fs::path p(expanded);
    if (p.is_relative()) {
        p = fs::absolute(base_dir / p);
    } else {
        p = fs::absolute(p);
    }
    return p.lexically_normal().string();
}

// Reads a text file line-by-line with CRLF cleanup.
bool read_file_lines(const fs::path &file_path, std::vector<std::string> &lines_out) {
    std::ifstream file(file_path);
    if (!file.is_open()) {
        return false;
    }

    std::string line;
    while (std::getline(file, line)) {
        if (!line.empty() && line.back() == '\r') {
            line.pop_back();
        }
        lines_out.push_back(line);
    }
    return true;
}

// Folds SPICE continuation lines that start with '+'.
std::vector<std::string> to_logical_lines(const std::vector<std::string> &physical_lines) {
    std::vector<std::string> logical_lines;
    for (const std::string &raw : physical_lines) {
        std::string trimmed = trim_copy(raw);
        if (!trimmed.empty() && trimmed.front() == '+' && !logical_lines.empty()) {
            logical_lines.back() += " " + trim_copy(trimmed.substr(1));
        } else {
            logical_lines.push_back(raw);
        }
    }
    return logical_lines;
}

// Rewrites .include/.lib paths to absolute paths, with optional PDK expansion.
std::string rewrite_include_or_lib(const std::string &line, const fs::path &base_dir, const std::string &pdk_root) {
    std::string trimmed = trim_copy(line);
    std::string lower = to_lower_copy(trimmed);
    bool is_include = starts_with_ci(lower, ".include");
    bool is_lib = starts_with_ci(lower, ".lib");
    if (!is_include && !is_lib) {
        return line;
    }

    std::istringstream iss(trimmed);
    std::string directive;
    std::string path_token;
    iss >> directive >> path_token;
    if (path_token.empty()) {
        return line;
    }

    bool was_quoted = (path_token.size() >= 2 && path_token.front() == '"' && path_token.back() == '"');
    std::string resolved = resolve_path_token(unquote_copy(path_token), base_dir, pdk_root);

    std::string rebuilt = directive + " " + maybe_quote(resolved, was_quoted);

    if (is_lib) {
        std::string section;
        if (iss >> section) {
            rebuilt += " " + section;
        }
    }
    return rebuilt;
}

// Rewrites input_file="..." paths to absolute normalized paths.
std::string rewrite_input_file_path(const std::string &line, const fs::path &base_dir, const std::string &pdk_root) {
    const std::string key = "input_file=\"";
    size_t start = line.find(key);
    if (start == std::string::npos) {
        return line;
    }

    size_t value_start = start + key.size();
    size_t value_end = line.find('"', value_start);
    if (value_end == std::string::npos) {
        return line;
    }

    std::string path_value = line.substr(value_start, value_end - value_start);
    std::string resolved = resolve_path_token(path_value, base_dir, pdk_root);
    return line.substr(0, value_start) + resolved + line.substr(value_end);
}

} // namespace

// Static instance for callbacks
CircuitSimulator* CircuitSimulator::instance = nullptr;

// Callback functions for ngspice *************************************************************
// Streams ngspice console output to Godot and an exposed signal.
static int ng_send_char(char *output, int id, void *user_data) {
    (void)id;
    (void)user_data;
    if (CircuitSimulator::instance) {
        CircuitSimulator::instance->call_deferred("emit_signal", "ngspice_output", String(output));
    }
    UtilityFunctions::print(String("[ngspice] ") + String(output));
    return 0;
}

// Receives status updates from ngspice (currently ignored).
static int ng_send_stat(char *status, int id, void *user_data) {
    (void)status;
    (void)id;
    (void)user_data;
    // Status updates during simulation
    return 0;
}

// Handles ngspice shutdown callback notifications.
static int ng_controlled_exit(int status, bool immediate, bool exit_on_quit, int id, void *user_data) {
    (void)status;
    (void)immediate;
    (void)exit_on_quit;
    (void)id;
    (void)user_data;
    UtilityFunctions::print("ngspice exit requested");
    return 0;
}

// Publishes streamed simulation samples while ngspice runs.
static int ng_send_data(pvecvaluesall data, int count, int id, void *user_data) {
    (void)count;
    (void)id;
    (void)user_data;
    // Called during simulation with new data points
    if (CircuitSimulator::instance && data != nullptr) {
        PackedFloat64Array sample;
        sample.resize(data->veccount);
        for (int i = 0; i < data->veccount; i++) {
            pvecvalues vec = data->vecsa[i];
            sample.set(i, vec->creal);
        }
        CircuitSimulator::instance->ingest_callback_sample(sample);
        CircuitSimulator::instance->call_deferred("emit_signal", "simulation_data_ready", sample);
    }
    return 0;
}

#ifdef XSPICE
// Receives event-node updates (XSPICE/event simulation path).
static int ng_send_evt_data(
    int node_index,
    double sim_time,
    double plot_value,
    char *print_value,
    void *raw_value,
    int value_type,
    int node_type,
    int more,
    void *user_data
) {
    (void)raw_value;
    (void)user_data;
    if (CircuitSimulator::instance) {
        Dictionary event_data;
        event_data["node_index"] = node_index;
        event_data["time"] = sim_time;
        event_data["plot_value"] = plot_value;
        event_data["print_value"] = print_value ? String(print_value) : String();
        event_data["value_type"] = value_type;
        event_data["node_type"] = node_type;
        event_data["more"] = more;
        CircuitSimulator::instance->call_deferred("emit_signal", "simulation_event_data", event_data);
    }
    return 0;
}

// Receives metadata for event nodes before event simulation starts.
static int ng_send_init_evt_data(
    int node_index,
    int udn_index,
    char *node_name,
    char *udn_name,
    int id,
    void *user_data
) {
    (void)id;
    (void)user_data;
    UtilityFunctions::print(
        "Event node initialized idx=" + String::num_int64(node_index) +
        " udn_idx=" + String::num_int64(udn_index) +
        " name=" + (node_name ? String(node_name) : String()) +
        " udn=" + (udn_name ? String(udn_name) : String())
    );
    return 0;
}
#endif

// Receives vector metadata once a simulation is initialized.
static int ng_send_init_data(pvecinfoall data, int id, void *user_data) {
    (void)id;
    (void)user_data;
    const int vector_count = (data != nullptr) ? data->veccount : 0;
    // Called before simulation with vector info
    if (CircuitSimulator::instance && data != nullptr) {
        PackedStringArray signal_names;
        for (int i = 0; i < data->veccount; i++) {
            if (data->vecs[i] != nullptr && data->vecs[i]->vecname != nullptr) {
                signal_names.append(String(data->vecs[i]->vecname));
            } else {
                signal_names.append(String());
            }
        }
        CircuitSimulator::instance->ingest_callback_signal_names(signal_names);
    }
    UtilityFunctions::print(String("Simulation initialized with ") + String::num_int64(vector_count) + " vectors");
    return 0;
}

// Emits lifecycle signals when the ngspice background thread starts/stops.
static int ng_bg_thread_running(bool running, int id, void *user_data) {
    (void)id;
    (void)user_data;
    if (CircuitSimulator::instance) {
        if (running) {
            CircuitSimulator::instance->call_deferred("emit_signal", "simulation_started");
        } else {
            CircuitSimulator::instance->call_deferred("emit_signal", "simulation_finished");
        }
    }
    return 0;
}

// Registers methods and signals exposed to GDScript.
void CircuitSimulator::_bind_methods() {
    // Minimal runtime API used by the current Godot UI.
    ClassDB::bind_method(D_METHOD("initialize_ngspice"), &CircuitSimulator::initialize_ngspice);
    ClassDB::bind_method(D_METHOD("load_netlist", "netlist_path", "pdk_root"), &CircuitSimulator::load_netlist, DEFVAL(""));

    ClassDB::bind_method(
        D_METHOD("start_continuous_transient", "step", "window", "sleep_ms"),
        &CircuitSimulator::start_continuous_transient,
        DEFVAL(int64_t(25))
    );
    ClassDB::bind_method(D_METHOD("stop_continuous_transient"), &CircuitSimulator::stop_continuous_transient);
    ClassDB::bind_method(D_METHOD("is_continuous_transient_running"), &CircuitSimulator::is_continuous_transient_running);
    ClassDB::bind_method(D_METHOD("get_continuous_memory_signal_names"), &CircuitSimulator::get_continuous_memory_signal_names);
    ClassDB::bind_method(
        D_METHOD("configure_continuous_memory_buffer", "signals", "max_samples"),
        &CircuitSimulator::configure_continuous_memory_buffer,
        DEFVAL(PackedStringArray()),
        DEFVAL(int64_t(10000))
    );
    ClassDB::bind_method(D_METHOD("clear_continuous_memory_buffer"), &CircuitSimulator::clear_continuous_memory_buffer);
    ClassDB::bind_method(D_METHOD("get_continuous_memory_snapshot"), &CircuitSimulator::get_continuous_memory_snapshot);
    ClassDB::bind_method(
        D_METHOD("pop_continuous_memory_samples", "count"),
        &CircuitSimulator::pop_continuous_memory_samples,
        DEFVAL(int64_t(256))
    );
    ClassDB::bind_method(D_METHOD("get_continuous_memory_sample_count"), &CircuitSimulator::get_continuous_memory_sample_count);

    // Signals
    ADD_SIGNAL(MethodInfo("simulation_started"));
    ADD_SIGNAL(MethodInfo("simulation_finished"));
    ADD_SIGNAL(MethodInfo("simulation_data_ready", PropertyInfo(Variant::PACKED_FLOAT64_ARRAY, "data")));
    ADD_SIGNAL(MethodInfo("simulation_event_data", PropertyInfo(Variant::DICTIONARY, "event")));
    ADD_SIGNAL(MethodInfo("ngspice_output", PropertyInfo(Variant::STRING, "message")));
    ADD_SIGNAL(MethodInfo("continuous_transient_started"));
    ADD_SIGNAL(MethodInfo("continuous_transient_stopped"));
    ADD_SIGNAL(MethodInfo("continuous_transient_frame", PropertyInfo(Variant::DICTIONARY, "frame")));
}

// Initializes simulator state and ngspice function pointers.
CircuitSimulator::CircuitSimulator() {
    initialized = false;
    current_netlist = "";
    ngspice_handle = nullptr;
    ng_Init = nullptr;
#ifdef XSPICE
    ng_Init_Evt = nullptr;
#endif
    ng_Command = nullptr;
    ng_Circ = nullptr;
    ng_Running = nullptr;
    continuous_stop_requested = false;
    continuous_running = false;
    continuous_step = 0.0;
    continuous_window = 0.0;
    continuous_next_start.store(0.0);
    continuous_last_time.store(0.0);
    continuous_sample_count.store(0);
    continuous_sleep_ms = 25;
    continuous_emit_stride = 64;
    buffer_stdout_stride = 10;
    callback_time_index.store(-1);
    memory_buffer_enabled = true;
    memory_max_samples = 10000;
    instance = this;
}

// Stops worker threads and releases ngspice resources.
CircuitSimulator::~CircuitSimulator() {
    stop_continuous_thread();
    clear_continuous_memory_buffer();
    if (initialized) {
        shutdown_ngspice();
    }
    if (instance == this) {
        instance = nullptr;
    }
}

// Dynamically loads the ngspice shared library and required symbols.
bool CircuitSimulator::load_ngspice_library() {
#ifdef _WIN32
    ngspice_handle = LoadLibraryA("ngspice.dll");
    if (!ngspice_handle) {
        // Try loading from bin folder
        ngspice_handle = LoadLibraryA("bin/ngspice.dll");
    }
    if (!ngspice_handle) {
        UtilityFunctions::printerr("Failed to load ngspice.dll");
        return false;
    }

    ng_Init = (int (*)(SendChar*, SendStat*, ControlledExit*, SendData*, SendInitData*, BGThreadRunning*, void*))
        GetProcAddress(ngspice_handle, "ngSpice_Init");
#ifdef XSPICE
    ng_Init_Evt = (int (*)(SendEvtData*, SendInitEvtData*, void*))
        GetProcAddress(ngspice_handle, "ngSpice_Init_Evt");
#endif
    ng_Command = (int (*)(char*))
        GetProcAddress(ngspice_handle, "ngSpice_Command");
    ng_Circ = (int (*)(char**))
        GetProcAddress(ngspice_handle, "ngSpice_Circ");
    ng_Running = (bool (*)())
        GetProcAddress(ngspice_handle, "ngSpice_running");
#else
    std::vector<std::string> candidates;
#ifdef __APPLE__
    candidates = {
        "libngspice.dylib",
        "./libngspice.dylib",
        "./bin/libngspice.dylib",
        "./project/bin/libngspice.dylib",
        "./ngspice/libngspice.dylib",
        "/opt/homebrew/lib/libngspice.dylib",
        "/usr/local/lib/libngspice.dylib",
        "libngspice.so",
        "./libngspice.so",
        "./bin/libngspice.so",
        "./project/bin/libngspice.so",
        "/opt/homebrew/lib/libngspice.so",
        "/usr/local/lib/libngspice.so"
    };
#else
    candidates = {
        "libngspice.so",
        "./libngspice.so",
        "./bin/libngspice.so",
        "./project/bin/libngspice.so",
        "/usr/lib/libngspice.so",
        "/usr/local/lib/libngspice.so"
    };
#endif

    String attempted_paths;
    String last_error;
    for (const std::string &candidate : candidates) {
        ngspice_handle = dlopen(candidate.c_str(), RTLD_NOW);
        if (ngspice_handle) {
            UtilityFunctions::print("Loaded ngspice library from: " + String(candidate.c_str()));
            break;
        }
        if (!attempted_paths.is_empty()) {
            attempted_paths += ", ";
        }
        attempted_paths += String(candidate.c_str());
        const char *err = dlerror();
        if (err) {
            last_error = String(err);
        }
    }

    if (!ngspice_handle) {
        UtilityFunctions::printerr("Failed to load ngspice library. Tried: " + attempted_paths);
        if (!last_error.is_empty()) {
            UtilityFunctions::printerr("Last dlopen error: " + last_error);
        }
        return false;
    }

    ng_Init = (int (*)(SendChar*, SendStat*, ControlledExit*, SendData*, SendInitData*, BGThreadRunning*, void*))
        dlsym(ngspice_handle, "ngSpice_Init");
#ifdef XSPICE
    ng_Init_Evt = (int (*)(SendEvtData*, SendInitEvtData*, void*))
        dlsym(ngspice_handle, "ngSpice_Init_Evt");
#endif
    ng_Command = (int (*)(char*))
        dlsym(ngspice_handle, "ngSpice_Command");
    ng_Circ = (int (*)(char**))
        dlsym(ngspice_handle, "ngSpice_Circ");
    ng_Running = (bool (*)())
        dlsym(ngspice_handle, "ngSpice_running");
#endif

    if (!ng_Init || !ng_Command) {
        UtilityFunctions::printerr("Failed to load required ngspice functions");
        unload_ngspice_library();
        return false;
    }

    return true;
}

// Releases the loaded ngspice shared library handle.
void CircuitSimulator::unload_ngspice_library() {
#ifdef _WIN32
    if (ngspice_handle) {
        FreeLibrary(ngspice_handle);
        ngspice_handle = nullptr;
    }
#else
    if (ngspice_handle) {
        dlclose(ngspice_handle);
        ngspice_handle = nullptr;
    }
#endif
}

// Initializes ngspice and wires callback hooks.
bool CircuitSimulator::initialize_ngspice() {
    if (initialized) {
        UtilityFunctions::print("ngspice already initialized");
        return true;
    }

    if (!load_ngspice_library()) {
        return false;
    }

    int ret = ng_Init(
        ng_send_char,
        ng_send_stat,
        ng_controlled_exit,
        ng_send_data,
        ng_send_init_data,
        ng_bg_thread_running,
        this
    );

    if (ret != 0) {
        UtilityFunctions::printerr("ngSpice_Init failed with code: " + String::num_int64(ret));
        unload_ngspice_library();
        return false;
    }

#ifdef XSPICE
    if (ng_Init_Evt) {
        int evt_ret = ng_Init_Evt(ng_send_evt_data, ng_send_init_evt_data, this);
        if (evt_ret != 0) {
            UtilityFunctions::printerr("ngSpice_Init_Evt failed with code: " + String::num_int64(evt_ret));
        }
    }
#endif

    initialized = true;
    UtilityFunctions::print("ngspice initialized successfully");
    return true;
}

// Stops activity and tears down embedded ngspice safely.
void CircuitSimulator::shutdown_ngspice() {
    stop_continuous_thread();
    clear_continuous_memory_buffer();

    if (!initialized) {
        return;
    }

    if (ng_Command) {
        // In embedded mode, quit may crash on some macOS/libngspice builds during teardown.
        // Halt background execution and reset state instead of invoking com_quit.
        ng_Command((char*)"bg_halt");
        if (ng_Running) {
            for (int i = 0; i < 50 && ng_Running(); i++) {
                std::this_thread::sleep_for(std::chrono::milliseconds(2));
            }
        }
        ng_Command((char*)"reset");
    }

    unload_ngspice_library();
    initialized = false;
    UtilityFunctions::print("ngspice shut down");
}

// Normalizes and loads a SPICE deck. Transient/save commands are API-driven.
Dictionary CircuitSimulator::load_netlist(const String &netlist_path, const String &pdk_root) {
    Dictionary result;

    if (!initialized) {
        UtilityFunctions::printerr("ngspice not initialized");
        return result;
    }

    if (!ng_Circ) {
        UtilityFunctions::printerr("ngSpice_Circ not available");
        return result;
    }

    CharString spice_utf8 = netlist_path.utf8();
    fs::path spice_fs_path = fs::absolute(fs::path(spice_utf8.get_data())).lexically_normal();
    fs::path base_dir = spice_fs_path.parent_path();
    std::string pdk_root_str = std::string(pdk_root.utf8().get_data());

    std::vector<std::string> physical_lines;
    if (!read_file_lines(spice_fs_path, physical_lines)) {
        UtilityFunctions::printerr(String("Failed to read .spice file: ") + String(spice_fs_path.string().c_str()));
        return result;
    }

    std::vector<std::string> logical_lines = to_logical_lines(physical_lines);
    std::vector<std::string> normalized_lines;

    bool inside_control = false;
    bool has_end = false;

    for (const std::string &original_line : logical_lines) {
        std::string trimmed = trim_copy(original_line);

        if (starts_with_ci(trimmed, ".control")) {
            inside_control = true;
            continue;
        }
        if (inside_control) {
            if (starts_with_ci(trimmed, ".endc")) {
                inside_control = false;
                continue;
            }
            continue;
        }

        std::string rewritten = rewrite_include_or_lib(original_line, base_dir, pdk_root_str);
        rewritten = rewrite_input_file_path(rewritten, base_dir, pdk_root_str);

        std::string rewritten_trimmed = trim_copy(rewritten);
        std::string rewritten_lower = to_lower_copy(rewritten_trimmed);
        if (rewritten_lower == ".end") {
            has_end = true;
        }
        normalized_lines.push_back(rewritten);
    }

    if (!has_end) {
        normalized_lines.push_back(".end");
    }

    std::vector<char *> circ_lines;
    circ_lines.reserve(normalized_lines.size() + 1);
    for (std::string &line : normalized_lines) {
        circ_lines.push_back(const_cast<char *>(line.c_str()));
    }
    circ_lines.push_back(nullptr);

    int load_ret = ng_Circ(circ_lines.data());
    if (load_ret != 0) {
        UtilityFunctions::printerr("ngSpice_Circ failed while loading normalized .spice lines");
        return result;
    }

    std::ostringstream netlist_stream;
    for (const std::string &line : normalized_lines) {
        netlist_stream << line << "\n";
    }
    current_netlist = String(netlist_stream.str().c_str());
    result["normalized_netlist"] = current_netlist;
    result["loaded"] = true;

    return result;
}

// Starts a looping transient stream that emits frame snapshots.
bool CircuitSimulator::start_continuous_transient(double step, double window, int64_t sleep_ms) {
    if (!initialized || !ng_Command) {
        UtilityFunctions::printerr("ngspice not initialized");
        return false;
    }
    if (step <= 0.0 || window <= 0.0) {
        UtilityFunctions::printerr("start_continuous_transient requires positive step and window");
        return false;
    }
    if (window <= step) {
        UtilityFunctions::printerr("start_continuous_transient requires stop_time > step");
        return false;
    }

    stop_continuous_thread();

    continuous_step = step;
    continuous_window = window;
    continuous_next_start.store(0.0);
    continuous_last_time.store(0.0);
    continuous_sample_count.store(0);
    continuous_sleep_ms = sleep_ms < 1 ? 1 : sleep_ms;
    continuous_emit_stride = 64;
    continuous_stop_requested = false;
    continuous_running = true;

    call_deferred("emit_signal", "continuous_transient_started");

    continuous_thread = std::thread([this]() {
        bool ok = true;

        {
            std::lock_guard<std::mutex> lock(ng_command_mutex);
            if (ng_Command((char *)"esave node") != 0) {
                UtilityFunctions::printerr("Continuous transient setup failed: esave node");
                ok = false;
            }
            if (ok && ng_Command((char *)"save none") != 0) {
                UtilityFunctions::printerr("Continuous transient setup failed: save none");
                ok = false;
            }
        }

        if (ok) {
            char cmd[256];
            snprintf(cmd, sizeof(cmd), "tran %g %g", continuous_step, continuous_window);
            std::lock_guard<std::mutex> lock(ng_command_mutex);
            if (ng_Command(cmd) != 0) {
                UtilityFunctions::printerr("Continuous transient start failed");
                ok = false;
            }
        }

        while (ok && !continuous_stop_requested.load()) {
            if (!ng_Running || !ng_Running()) {
                break;
            }
            std::this_thread::sleep_for(std::chrono::milliseconds(continuous_sleep_ms));
        }

        continuous_running = false;
        call_deferred("emit_signal", "continuous_transient_stopped");
    });

    return true;
}

// Signals and joins the continuous worker thread.
void CircuitSimulator::stop_continuous_thread() {
    continuous_stop_requested = true;
    if (initialized && ng_Command) {
        std::unique_lock<std::mutex> lock(ng_command_mutex, std::try_to_lock);
        if (lock.owns_lock()) {
            ng_Command((char *)"bg_halt");
        }
    }
    if (continuous_thread.joinable()) {
        continuous_thread.join();
    }
    continuous_running = false;
}

// Public wrapper to stop continuous transient streaming.
void CircuitSimulator::stop_continuous_transient() {
    stop_continuous_thread();
}

// Reports whether continuous transient mode is active.
bool CircuitSimulator::is_continuous_transient_running() const {
    return continuous_running.load();
}

// Resolves callback time using the discovered "time" vector index.
double CircuitSimulator::resolve_callback_time(const PackedFloat64Array &sample) const {
    int32_t time_index = callback_time_index.load();

    if (time_index >= 0 && time_index < sample.size()) {
        return sample[time_index];
    }
    return continuous_last_time.load() + continuous_step;
}

// Handles callback sample fanout for memory buffering and periodic stream frames.
void CircuitSimulator::handle_continuous_callback_sample(const PackedFloat64Array &sample) {
    const int64_t sample_count = continuous_sample_count.fetch_add(1) + 1;
    push_memory_sample(sample, sample_count);

    const double sample_time = resolve_callback_time(sample);
    continuous_last_time.store(sample_time);
    continuous_next_start.store(sample_time);

    if (continuous_running.load() && continuous_emit_stride > 0 && (sample_count % continuous_emit_stride == 0)) {
        Dictionary frame;
        frame["time"] = sample_time;
        frame["sample_count"] = sample_count;
        frame["step"] = continuous_step;
        frame["stop"] = continuous_window;
        call_deferred("emit_signal", "continuous_transient_frame", frame);
    }
}

// Returns names for values stored in continuous memory samples.
PackedStringArray CircuitSimulator::get_continuous_memory_signal_names() const {
    std::lock_guard<std::mutex> lock(memory_mutex);
    return memory_signal_names;
}

// Rebuilds name-based memory filter into vector indices for fast callback ingestion.
void CircuitSimulator::refresh_memory_filter_indices_locked() {
    memory_signal_indices.clear();
    memory_signal_names.clear();
    if (memory_signal_filter.is_empty()) {
        memory_signal_names = callback_signal_names;
        return;
    }

    for (int i = 0; i < memory_signal_filter.size(); i++) {
        const String &requested = memory_signal_filter[i];
        const String requested_lower = requested.to_lower();
        for (int j = 0; j < callback_signal_names.size(); j++) {
            if (callback_signal_names[j].to_lower() == requested_lower) {
                memory_signal_indices.append(j);
                memory_signal_names.append(callback_signal_names[j]);
                break;
            }
        }
    }
}

// Stores one callback sample while enforcing optional signal filtering and max buffer size.
void CircuitSimulator::push_memory_sample(const PackedFloat64Array &sample, int64_t sample_count) {
    if (!memory_buffer_enabled.load()) {
        return;
    }

    PackedFloat64Array to_store;
    {
        std::lock_guard<std::mutex> lock(memory_mutex);
        if (memory_signal_filter.is_empty()) {
            to_store = sample;
        } else if (!memory_signal_indices.is_empty()) {
            to_store.resize(memory_signal_indices.size());
            for (int i = 0; i < memory_signal_indices.size(); i++) {
                const int32_t source_index = memory_signal_indices[i];
                if (source_index >= 0 && source_index < sample.size()) {
                    to_store.set(i, sample[source_index]);
                } else {
                    to_store.set(i, 0.0);
                }
            }
        }

        if (to_store.is_empty()) {
            return;
        }

        memory_samples.push_back(to_store);
        while (static_cast<int64_t>(memory_samples.size()) > memory_max_samples) {
            memory_samples.pop_front();
        }

        if (buffer_stdout_stride > 0 && (sample_count % buffer_stdout_stride == 0)) {
            const int64_t buffer_size = static_cast<int64_t>(memory_samples.size());
            const int preview_count = std::min<int>(to_store.size(), 8);
            std::ostringstream oss;
            oss << "[buffer] sample=" << sample_count
                << " size=" << buffer_size
                << " width=" << to_store.size()
                << " values=";
            for (int i = 0; i < preview_count; i++) {
                String label = i < memory_signal_names.size() ? memory_signal_names[i] : String("vec_") + String::num_int64(i);
                if (i > 0) {
                    oss << " | ";
                }
                oss << std::string(label.utf8().get_data()) << "=" << std::setprecision(16) << to_store[i];
            }
            if (to_store.size() > preview_count) {
                oss << " | ...";
            }
            UtilityFunctions::print(String(oss.str().c_str()));
        }
    }
}

// Caches callback vector ordering once per simulation run.
void CircuitSimulator::ingest_callback_signal_names(const PackedStringArray &signal_names) {
    std::lock_guard<std::mutex> lock(memory_mutex);
    callback_signal_names = signal_names;
    callback_time_index.store(-1);
    for (int i = 0; i < callback_signal_names.size(); i++) {
        if (callback_signal_names[i].to_lower() == "time") {
            callback_time_index.store(i);
            break;
        }
    }
    refresh_memory_filter_indices_locked();
    memory_samples.clear();
}

// Public wrapper used by ngspice callbacks to feed in-memory samples.
void CircuitSimulator::ingest_callback_sample(const PackedFloat64Array &sample) {
    handle_continuous_callback_sample(sample);
}

// Enables callback-driven in-memory buffering for continuous animation data.
bool CircuitSimulator::configure_continuous_memory_buffer(const PackedStringArray &signals, int64_t max_samples) {
    if (max_samples < 1) {
        max_samples = 1;
    }

    std::lock_guard<std::mutex> lock(memory_mutex);
    memory_samples.clear();
    memory_signal_filter = signals;
    refresh_memory_filter_indices_locked();
    memory_max_samples = max_samples;
    memory_buffer_enabled = true;
    return true;
}

// Clears buffered callback samples but keeps configuration intact.
void CircuitSimulator::clear_continuous_memory_buffer() {
    std::lock_guard<std::mutex> lock(memory_mutex);
    memory_samples.clear();
}

// Returns all buffered callback samples without removing them.
Array CircuitSimulator::get_continuous_memory_snapshot() const {
    Array out;
    std::lock_guard<std::mutex> lock(memory_mutex);
    for (const PackedFloat64Array &sample : memory_samples) {
        out.append(sample);
    }
    return out;
}

// Pops up to count oldest callback samples for incremental consumers.
Array CircuitSimulator::pop_continuous_memory_samples(int64_t count) {
    Array out;
    if (count <= 0) {
        return out;
    }

    std::lock_guard<std::mutex> lock(memory_mutex);
    const int64_t take = std::min<int64_t>(count, static_cast<int64_t>(memory_samples.size()));
    for (int64_t i = 0; i < take; i++) {
        out.append(memory_samples.front());
        memory_samples.pop_front();
    }
    return out;
}

// Returns buffered callback sample count.
int64_t CircuitSimulator::get_continuous_memory_sample_count() const {
    std::lock_guard<std::mutex> lock(memory_mutex);
    return static_cast<int64_t>(memory_samples.size());
}
