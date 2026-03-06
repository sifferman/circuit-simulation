#ifndef CIRCUIT_SIM_H
#define CIRCUIT_SIM_H

#include <godot_cpp/classes/node.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/dictionary.hpp>
#include <godot_cpp/variant/array.hpp>
#include <godot_cpp/variant/packed_float64_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/packed_string_array.hpp>
#include <atomic>
#include <cstdint>
#include <deque>
#include <mutex>
#include <thread>
#include <vector>

#ifdef _WIN32
#include <windows.h>
#else
#include <dlfcn.h>
#endif

#include "sharedspice.h"

namespace godot {

class CircuitSimulator : public Node {
    GDCLASS(CircuitSimulator, Node)

private:
    bool initialized;
    String current_netlist;

    // Dynamic library handle
#ifdef _WIN32
    HMODULE ngspice_handle;
#else
    void* ngspice_handle;
#endif

    // Function pointers for ngspice API
    int (*ng_Init)(SendChar*, SendStat*, ControlledExit*, SendData*, SendInitData*, BGThreadRunning*, void*);
#ifdef XSPICE
    int (*ng_Init_Evt)(SendEvtData*, SendInitEvtData*, void*);
#endif
    int (*ng_Command)(char*);
    int (*ng_Circ)(char**);
    bool (*ng_Running)();

    // Load ngspice dynamically
    bool load_ngspice_library();
    void unload_ngspice_library();

    std::mutex ng_command_mutex;

    // Continuous transient loop state.
    std::thread continuous_thread;
    std::atomic<bool> continuous_stop_requested;
    std::atomic<bool> continuous_running;
    double continuous_step;
    double continuous_window;
    std::atomic<double> continuous_next_start;
    std::atomic<double> continuous_last_time;
    std::atomic<int64_t> continuous_sample_count;
    int64_t continuous_sleep_ms;
    int64_t continuous_emit_stride;
    int64_t buffer_stdout_stride;
    std::atomic<int32_t> callback_time_index;
    void stop_continuous_thread();
    double resolve_callback_time(const PackedFloat64Array &sample) const;
    void handle_continuous_callback_sample(const PackedFloat64Array &sample);
    void push_memory_sample(const PackedFloat64Array &sample, int64_t sample_count);
    void refresh_memory_filter_indices_locked();

    // Optional in-memory sample buffer for callback-driven animation data.
    std::deque<PackedFloat64Array> memory_samples;
    PackedStringArray callback_signal_names;
    PackedStringArray memory_signal_filter;
    PackedStringArray memory_signal_names;
    PackedInt32Array memory_signal_indices;
    std::atomic<bool> memory_buffer_enabled;
    int64_t memory_max_samples;
    mutable std::mutex memory_mutex;

protected:
    static void _bind_methods();

public:
    CircuitSimulator();
    ~CircuitSimulator();

    // Initialization
    bool initialize_ngspice();
    void shutdown_ngspice();

    // Circuit loading
    Dictionary load_netlist(const String &netlist_path, const String &pdk_root = "");

    // Simulation control
    bool start_continuous_transient(double step, double window, int64_t sleep_ms = 25);
    void stop_continuous_transient();
    bool is_continuous_transient_running() const;
    PackedStringArray get_continuous_memory_signal_names() const;

    // Callback ingestion entry points.
    void ingest_callback_signal_names(const PackedStringArray &signal_names);
    void ingest_callback_sample(const PackedFloat64Array &sample);

    bool configure_continuous_memory_buffer(const PackedStringArray &signals = PackedStringArray(), int64_t max_samples = 10000);
    void clear_continuous_memory_buffer();
    Array get_continuous_memory_snapshot() const;
    Array pop_continuous_memory_samples(int64_t count = 256);
    int64_t get_continuous_memory_sample_count() const;

    // Static instance for callbacks
    static CircuitSimulator* instance;
};

} // namespace godot

#endif // CIRCUIT_SIM_H
