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

* One based on a Ruby native extension in `gems/native-tracer`
* Another based on pure Ruby code in `gems/pure-ruby-tracer`

Their outputs are compared structurally to known good outputs stored
in `test/fixtures`.

When `just test` fails, I suggest running the two tracers directly and
analyzing where their outputs differs.

Please note that only the pure-ruby-tracer formats the output json for
human readability. Thus, you must use `jq -S` when comparing the outputs.

To run the benchmark, execute:

```
just bench
```

# You don't have access to the internet

During development, certain commands will fail because you don't have
access to the internet.

The script `.codex/internet_resources/download.sh` is executed before
your development session starts while your computer is still connected
to the internet.

You can examine this script to see what kind of internet resources
have been downloaded for offline use. If it's difficult for you to
achieve a task without access to additional internet resources, you
can always propose a PR that modifies the download.sh script instead
of completing your main task.

Downloading development dependencies may also fail due to the lack of
internet connectivity. We are trying to maintain the script `.codex/build_all_targets.sh`
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

# Code quality guidelines

- Strive to achieve high code quality.
- Write secure code.
- Make sure the code is well tested and edge cases are covered. Design the code for testability.
- Write defensive code and make sure all potential errors are handled.
- Strive to write highly reusable code with routines that have high fan in and low fan out.
- Keep the code DRY.
- Aim for low coupling and high cohesion. Encapsulate and hide implementation details.

# Code commenting guidelines

- Document public APIs and complex modules.
- Maintain the comments together with the code to keep them meaningful and current.
- Comment intention and rationale, not obvious facts. Write self-documenting code.
- When implementing specific formats, standards or other specifications, make sure to
  link to the relevant spec URLs.

# Writing git commit messages

The first line of the commit message should follow the "conventional commits" style:
https://www.conventionalcommits.org/en/v1.0.0/

In the remaining lines, provide a short description of the implemented functionality.
Provide sufficient details for the justification of each design decision if multiple
approaches were considered.
