# Circuit Simulator

A Godot 4.5 GDExtension project for visualizing and simulating electronic circuits. Parses xschem `.sch` schematics and `.sym` symbol files, renders them in 2D/3D, and optionally runs SPICE simulations via ngspice.

## Setup

### 1. Clone with submodules

```bash
git clone --recursive https://github.com/ismilesen/circuit-simulator.git
cd circuit-simulator
```

If you already cloned without `--recursive`:

```bash
git submodule update --init --recursive
```

### 2. Build the GDExtension

```bash
scons
```

This compiles the C++ source in `src/` and places the resulting shared library in `project/bin/`.

### 3. ngspice (optional, for simulation)

The simulator dynamically loads ngspice at runtime. To enable simulation:

1. Download ngspice from https://ngspice.sourceforge.io/
<<<<<<< HEAD
2. Place `ngspice.dll` (Windows) or `libngspice.so` (Linux) and `sharedspice.h` in a new folder named `ngspice`.
=======
2. Place `ngspice.dll` (Windows) or `libngspice.so` (Linux) where Godot can find it (e.g. `project/bin/`).
>>>>>>> cd7f9eb (visualization and simulation addition)
3. If building with ngspice headers, uncomment and set the `CPPPATH` line in `SConstruct`.

### 4. Open in Godot

Open the `project/` folder as a Godot project (Godot 4.5+).

## Adding circuit files

- Place `.sym` symbol files in `project/symbols/sym/`
- Place `.sch` schematic files in `project/schematics/`
- You can also drag-and-drop files into the running application via the upload panel.

## Project structure

```
circuit-simulator/
├── godot-cpp/          # Git submodule (Godot C++ bindings)
├── src/                # C++ GDExtension source (CircuitSimulator, SchParser)
├── project/            # Godot project
│   ├── bin/            # Built shared libraries + .gdextension
│   ├── camera/         # 3D camera controller
│   ├── parser/         # GDScript .sym parser
│   ├── scripts/        # 3D circuit visualizer script
│   ├── symbols/        # Circuit symbol GDScript + sym/ for .sym files
│   ├── schematics/     # Place .sch files here
│   └── ui/             # Upload panel and sidebar UI
│   └── visualizer/
│   └── simulator/
├── SConstruct          # Build configuration
└── README.md
```
