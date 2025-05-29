# Instructions for Codex

To build the Rust native extension, execute:

```
just build-extension
```

To run the test suite, execute:

```
just test
```

The test suite executes a number of sample programs in `test/programs` under
the two separate recorders/tracers:

* One based on a Ruby native extension in `gems/codetracer-ruby-recorder`
* Another based on pure Ruby code in `gems/codetracer-pure-ruby-recorder`

Their outputs are compared structurally to known good outputs stored
in `test/fixtures`.

When `just test` fails, I suggest running the two tracers directly and
analyzing where their outputs differ.

Please note that only the codetracer-pure-ruby-recorder formats the output json for
human readability. Thus, you must use `jq -S` when comparing the outputs.

To run the benchmark, execute:

```
just bench
```

# You don't have access to the internet

During development, certain commands will fail because you don't have
access to the internet.

The script `.agents/download_internet_resources.sh` is executed before
your development session starts while your computer is still connected
to the internet.

You can examine this script to see what kind of internet resources
have been downloaded for offline use. If it's difficult for you to
achieve a task without access to additional internet resources, you
can always propose a PR that modifies the download.sh script instead
of completing your main task.

Downloading development dependencies may also fail due to the lack of
internet connectivity. We are trying to maintain the script `.agents/codex-setup`
that is also executed before your development session starts while
your computer is still connected to the internet. It tries to run
all build commands that need development dependencies in order to
cache the dependencies for offline use. Please propose changes to
this script when you introduce new build targets with dependencies.

When you need to consult the documentation or source code modules
for a particular dependency, always try to find where this dependency
have been downloaded and try to access the necessary files through
the file system (i.e. depending on the programming language, the
operating system and the package manager being used, they should
be in their standard location).

# Keeping notes

In the `.agents/codebase-insights.txt` file, we try to maintain useful tips that may help
you in your development tasks. When you discover something important or surprising about
the codebase, add a remark in a comment near the relevant code or in the codebase-insights
file. ALWAYS remove older remarks if they are no longer true.

You can consult this file before starting your coding tasks.

# Code quality guidelines

- ALWAYS strive to achieve high code quality.
- ALWAYS write secure code.
- ALWAYS make sure the code is well tested and edge cases are covered. Design the code for testability and be extremely thorough.
- ALWAYS write defensive code and make sure all potential errors are handled.
- ALWAYS strive to write highly reusable code with routines that have high fan in and low fan out.
- ALWAYS keep the code DRY.
- Aim for low coupling and high cohesion. Encapsulate and hide implementation details.
- When creating executable, ALWAYS make sure the functionality can also be used as a library.
  To achieve this, avoid global variables, raise/return errors instead of terminating the program, and think whether the use case of the library requires more control over logging and metrics from the application that integrates the library.

# Code commenting guidelines

- Document public APIs and complex modules using standard code documentation conventions.
- Comment the intention behind you code extensively. Omit comments only for very obvious
  facts that almost any developer would know.
- Maintain the comments together with the code to keep them meaningful and current.
- When the code is based on specific formats, standards or well-specified behavior of
  other software, always make sure to include relevant links (URLs) that provide the
  necessary technical details.

# Writing git commit messages

- You MUST use multiline git commit messages.
- Use the convential commits style for the first line of the commit message.
- Use the summary section of your final response as the remaining lines in the commit message.
