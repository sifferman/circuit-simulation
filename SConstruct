#!/usr/bin/env python
import os

env = SConscript("godot-cpp/SConstruct")

# Our C++ source
env.Append(CPPPATH=["src/"])

# ngspice headers — uncomment and adjust if you have ngspice installed locally:
# env.Append(CPPPATH=["path/to/ngspice/include/"])

# Source files
sources = Glob("src/*.cpp")

# Build the shared library into project/bin/
library = env.SharedLibrary(
    "project/bin/libcircuit_sim{}{}".format(env["suffix"], env["SHLIBSUFFIX"]),
    source=sources,
)

Default(library)
