This directory contains programs and fixtures used for manual performance testing of the tracer.

These benchmarks are **not** executed in CI because they may take longer to run than typical tests. Each program has a reference trace recorded using the current tracer implementation. When we experiment with alternative tracer implementations, we will compare their output with these fixtures to ensure compatibility.

The reference traces are stored via Git LFS so the repository stays lightweight.

At the moment there is a single benchmark (`heavy_work`) that exercises a mixture of array and hash operations while computing prime numbers. More benchmarks will be added as we expand the suite.

Use `run_benchmarks.rb --write-report=console BENCHMARKS_DIR` to execute a single benchmark and print the runtime. Passing a path ending with `.json` or `.svg` will run all benchmarks and write a report in the chosen format.
