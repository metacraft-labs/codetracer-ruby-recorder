# frozen_string_literal: true

# Where a recorded source file goes under `meta_dat/sources/`. No mocks: the
# real mapping is called, and the bundling test copies a real file into a
# real temporary directory.

require 'minitest/autorun'
require 'tmpdir'
require_relative '../gems/codetracer-ruby-recorder/lib/codetracer_ruby_recorder'

class BundledSourcePathTest < Minitest::Test
  def mapped(path)
    CodeTracer::RubyRecorder.bundled_source_relative_path(path)
  end

  def test_posix_absolute_path_loses_its_root
    assert_equal 'home/u/app.rb', mapped('/home/u/app.rb')
  end

  def test_relative_path_is_unchanged
    assert_equal 'test/programs/x.rb', mapped('test/programs/x.rb')
  end

  # mkdir refuses a `C:` component on Windows (Errno::EINVAL), so a drive
  # path must not keep its drive.
  def test_windows_drive_paths_lose_the_drive
    assert_equal 'Users/a/x.rb', mapped('C:/Users/a/x.rb')
    assert_equal 'Users\\a\\x.rb', mapped('d:\\Users\\a\\x.rb')
  end

  def test_bundling_writes_both_the_given_and_the_absolute_path
    Dir.mktmpdir do |dir|
      program = File.join(dir, 'prog.rb')
      File.write(program, "puts 1\n")
      out = File.join(dir, 'out')
      # Expanded inside the chdir, as the recorder expands it: the working
      # directory may resolve through a symlink (macOS /tmp is /private/tmp).
      expanded = nil
      Dir.chdir(dir) do
        expanded = File.expand_path('prog.rb')
        CodeTracer::RubyRecorder.bundle_source_file('prog.rb', out)
      end
      sources = File.join(out, 'meta_dat', 'sources')
      assert File.file?(File.join(sources, 'prog.rb'))
      absolute = File.join(sources, mapped(expanded))
      assert File.file?(absolute), "missing #{absolute}"
    end
  end
end
