# Copyright (c) 2011-2015 CrystaX.
# All rights reserved.
#
# Redistribution and use in source and binary forms, with or without modification, are
# permitted provided that the following conditions are met:
#
#    1. Redistributions of source code must retain the above copyright notice, this list of
#       conditions and the following disclaimer.
#
#    2. Redistributions in binary form must reproduce the above copyright notice, this list
#       of conditions and the following disclaimer in the documentation and/or other materials
#       provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY CrystaX ''AS IS'' AND ANY EXPRESS OR IMPLIED
# WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND
# FITNESS FOR A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL CrystaX OR
# CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR
# SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON
# ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING
# NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF
# ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
#
# The views and conclusions contained in the software and documentation are those of the
# authors and should not be interpreted as representing official policies, either expressed
# or implied, of CrystaX.

require 'fileutils'
require 'open3'
require 'json'
require 'securerandom'

require_relative 'log'
require_relative 'mro'

class Project
    attr_reader :path, :name

    WINDOWS = RUBY_PLATFORM =~ /(cygwin|mingw|win32)/ ? true : false

    CMAKE_MINIMUM_VERSION = '3.2'

    class MkdirFailed < Exception; end

    def initialize(path, ndk, options = {})
        raise "No such directory: #{path}" unless File.directory?(path)

        @ndkbuild = File.join(ndk, "ndk-build#{'.cmd' if WINDOWS}")
        raise "Wrong NDK path: #{ndk}" unless File.executable?(@ndkbuild)

        @ndk = ndk
        @path = path
        @name = File.basename(@path)
        @options = options

        @type = options[:type] || 'unknown'

        @outdir = options[:outdir]
        @tmpdir = File.join(@outdir, @type, @name)

        @jobs = options[:jobs] || 1

        @adb = options[:adb]

        propf = File.join(path, 'properties.json')
        if File.exists?(propf)
            @properties = JSON.parse(File.read(propf))
        else
            @properties = {}
        end

        @display_type = case @type
                        when 'samples'
                            'sample'
                        else
                            "#{@type} test"
                        end

        @emutag = options[:emutag]
        @abis   = options[:abis]

        @stimeout = @properties['single-run-timeout'] || options[:stimeout]

        @last_notice = Time.now
    end

    def gnumake
        if @gnumake.nil?
            case RUBY_PLATFORM
            when /linux/
                tag = 'linux'
            when /darwin/
                tag = 'darwin'
            when /(cygwin|mingw|win32)/
                tag = 'windows'
            else
                raise "Unknown RUBY_PLATFORM: #{RUBY_PLATFORM}"
            end

            if RUBY_PLATFORM =~ /linux/
                ft = `file -b /bin/ls`.chomp
                if ft =~ /64-bit/
                    harch = 'x86_64'
                elsif ft =~ /32-bit/
                    harch = 'x86'
                else
                    harch = RbConfig::CONFIG['host_cpu']
                end
            else
                harch = RbConfig::CONFIG['host_cpu']
                harch = 'x86' if harch =~ /^i\d86$/
            end
            archs = [harch]
            archs << 'x86' if harch == 'x86_64'

            archs.each do |arch|
                if tag == 'windows' && arch == 'x86'
                    host_tag = 'windows'
                else
                    host_tag = "#{tag}-#{arch}"
                end
                make = File.join(@ndk, 'prebuilt', host_tag, 'bin', "make#{".exe" if RUBY_PLATFORM =~ /(cygwin|mingw|win32)/}")
                next unless File.exists?(make)
                @gnumake = make
                break
            end
            raise "Can't find 'make' in #{@ndk}" if @gnumake.nil?
        end

        @gnumake
    end

    def cmake
        if @cmake.nil?
            @cmake = 'cmake'
        end
        @cmake
    end

    def cleanup
        FileUtils.rm_rf tmpdir
    end

    def tmpdir(options = {})
        return @tmpdir if options[:pie].nil?
        File.join(@tmpdir, "target#{"+PIE" if options[:pie]}")
    end

    def broken?
        return true if @properties['broken'].to_s =~ /^(true|yes|1)/i

        if !@options[:toolchain_version].nil?
            if @options[:toolchain_version] =~ /^([^\d-]+)/
                tt = $1
                tvt = @properties['broken-toolchain-type'] || []
                tvt = [tvt] unless tvt.is_a?(Array)
                tvt.each do |t|
                    return true if t == tt
                end
            end

            tvs = @properties['broken-toolchain-version'] || []
            tvs = [tvs] unless tvs.is_a?(Array)
            tvs.each do |t|
                return true if t == @options[:toolchain_version]
            end
        end

        false
    end

    def long?
        @properties['long'].to_s =~ /^(true|yes|1)/i ? true : false
    end

    def has_build_script?
        File.send(WINDOWS ? 'exists?' : 'executable?', File.join(path, 'build.sh'))
    end

    def has_cmakelists?
        File.exists?(File.join(path, 'CMakeLists.txt'))
    end

    def elapsed(seconds)
        s = seconds.to_i % 60
        m = (seconds.to_i / 60) % 60
        h = seconds.to_i / 3600
        "%d:%02d:%02d" % [h,m,s]
    end
    private :elapsed

    def log_info(msg)
        Log.info msg
    end
    private :log_info

    def log_notice(msg)
        Log.notice msg
        @last_notice = Time.now
    end
    private :log_notice

    def preprocess(cc, str)
        o,e,s = Open3.capture3("#{cc} -x c -E -", stdin_data: str)
        raise "Can't preprocess '#{str}' with #{cc}: #{e}" unless s.success?
        o.split("\n").reject { |line| line =~ /^#/ }.join("\n")
    end
    private :preprocess

    def run_cmd(cmd, options = {}, &block)
        log_info "## COMMAND: #{cmd}"
        log_info "## CWD: #{Dir.pwd}"
        Open3.popen3(options[:env] || {}, cmd) do |i,o,e,t|
            [i,o,e].each { |io| io.sync = true }

            ot = Thread.start do
                while line = o.gets.chomp rescue nil
                    if !options[:mroprefix].nil? && line =~ /^#{options[:mroprefix]}/
                        begin
                            line.sub!(/^#{options[:mroprefix]}/, '')
                            obj = JSON.parse(line)
                            yield obj
                        rescue
                            Log.warning "Can't handle MRO output: #{line}"
                        end
                        next
                    end
                    log_info "   > #{line}"
                end
            end

            mkdir_error = false
            et = Thread.start do
                while line = e.gets.chomp rescue nil
                    log_info "   * #{line}"
                    mkdir_error = true if options[:track_mkdir_errors] && line =~ /^mkdir:/
                end
            end

            wt = Thread.start do
                lt = Time.now
                while ot.alive? || et.alive?
                    sleep 5
                    now = Time.now
                    next if now - @last_notice < 30
                    log_notice "## STILL RUNNING (#{elapsed(now - lt)})"
                end
            end

            i.close
            ot.join
            et.join
            wt.kill

            errmsg = options[:errmsg] || "'#{cmd}' failed"
            raise MkdirFailed.new(errmsg) if mkdir_error && !t.value.success?
            raise errmsg unless t.value.success?
        end

    end
    private :run_cmd

    def run_on_host
        # If there is 'host/GNUmakefile', that means this test is capable to run on host too.
        # In this case, before we build test with NDK build system, we build and run it on host,
        # ensuring there is no errors in this test running on host OS.
        # For maximum coverage, we use wide range of C/C++ compilers and test with all of them
        # we can found on host
        # Requirements for on-host tests:
        # - there should be host/GNUmakefile file in test directory
        # - that GNUmakefile should support 'test' target, which build and run test on host
        # - that GNUmakefile should allow redefining of CC and CXX variables and use them for
        #   test build

        # Allow on-host testing on Linux/Darwin hosts only
        return if RUBY_PLATFORM !~ /(linux|darwin)/
        # Disable on-host testing if there is no host/GNUmakefile or CMakeLists.txt
        return if !File.exists?(File.join(path, 'host', 'GNUmakefile')) && !has_cmakelists?
        # Disable on-host testing if it was explicitly requested
        return if ENV['DISABLE_ONHOST_TESTING'] == 'yes'

        dos = @properties['onhost-disabled-os'] || []
        dos = [dos] unless dos.is_a?(Array)
        dos.each do |os|
            return if RUBY_PLATFORM =~ /#{os}/
        end

        log_notice "HST #{@display_type} [#{name}]"

        ccs = []

        [
            'cc',
            'gcc',
            'gcc-4.9',
            'gcc-5',
            'gcc-6',
            'clang',
            'clang-3.6',
            'clang-3.7',
            'clang-3.8',
        ].each do |cc|
            found = false
            ENV['PATH'].split(':').each do |p|
                next if !File.executable?(File.join(p, cc))
                found = true
                break
            end
            next unless found

            if preprocess(cc, "__clang__") != "__clang__"
                type = :clang
                version = preprocess(cc, "__clang_version__")
            elsif preprocess(cc, "__GNUC__") != "__GNUC__"
                type = :gcc
                version = preprocess(cc, "__VERSION__")
            else
                raise "Can't detect type of #{cc}"
            end

            ccs << {exe: cc, type: type, version: version} if ccs.select { |x| x[:type] == type && x[:version] == version }.empty?
        end

        if @options[:toolchain_version]
            ndk_toolchain_type = @options[:toolchain_version] =~ /^clang/ ? :clang : :gcc
            ccs.select! { |e| e[:type] == ndk_toolchain_type }
        end

        ccs = [{exe: 'cc'}] if ccs.empty?

        ccs.map { |e| e[:exe] }.each do |cc|
            dcc = @properties['onhost-disabled-cc'] || []
            dcc = [dcc] unless dcc.is_a?(Array)
            next if dcc.select { |d| d == cc }.size > 0

            dir = File.join(tmpdir, "host-#{cc}")
            FileUtils.rm_rf dir
            FileUtils.mkdir_p File.dirname(dir)
            FileUtils.cp_r path, dir

            File.open(File.join(dir, 'CMakeLists.txt'), 'w') do |bf|
                cmakelists = File.read(File.join(path, 'CMakeLists.txt'))
                if cmakelists.split("\n").select { |line| line =~ /^\s*cmake_minimum_required\s*\(/i }.empty?
                    bf.puts "cmake_minimum_required(VERSION #{CMAKE_MINIMUM_VERSION} FATAL_ERROR)"
                    bf.puts ''
                end
                bf.write cmakelists
                if cmakelists.split("\n").select { |line| line =~ /^\s*enable_testing\s*\(/i }.empty?
                    bf.puts ''
                    bf.puts 'enable_testing()'
                    bf.puts 'add_test(NAME ${TARGET} COMMAND $<TARGET_FILE:${TARGET}>)'
                end
            end if has_cmakelists?

            File.open(File.join(dir, 'run.sh'), 'w') do |bf|
                bf.puts '#!/bin/sh'
                bf.puts "export GNUMAKE='#{gnumake}'"
                bf.puts "export JOBS=#{@jobs}"
                bf.puts 'run()'
                bf.puts '{'
                bf.puts '    echo "## COMMAND: $@"'
                bf.puts '    "$@"'
                bf.puts '}'
                if File.exists?(File.join(dir, 'CMakeLists.txt'))
                    bf.puts "run rm -Rf #{dir}/cmake-build || exit 1"
                    bf.puts "run mkdir -p #{dir}/cmake-build || exit 1"
                    bf.puts "run cd #{dir}/cmake-build || exit 1"
                    bf.puts "run cmake -DCMAKE_C_COMPILER=#{cc} -DCMAKE_CXX_COMPILER=#{cc} #{dir} || exit 1"
                    bf.puts "run #{gnumake} -j#{@jobs} VERBOSE=1 || exit 1"
                    bf.puts "run #{gnumake} test VERBOSE=1 || exit 1"
                elsif File.exists?(File.join(dir, 'host', 'GNUmakefile'))
                    bf.puts "run #{gnumake} -C #{File.join(dir, 'host')} -B -j#{@jobs} test CC=#{cc}"
                else
                    raise "Don't know how to run on-host testing for this test!"
                end
                bf.puts "exit 0"
            end
            FileUtils.chmod 0755, File.join(dir, 'run.sh')

            max_attempts = 5
            attempt = 1
            begin
                run_cmd File.join(dir, 'run.sh'), errmsg: "On-host test of #{name} failed", track_mkdir_errors: true
            rescue MkdirFailed
                attempt += 1
                raise "On-host testing of project #{name} failed" if attempt > max_attempts
                log_info "WARNING: On-host testing of '#{name}' failed due to 'mkdir' error; trying again (attempt ##{attempt})"
                retry
            end

            FileUtils.rm_rf dir
        end

        log_info "== OK: all on-host tests PASSED"
    rescue => e
        log_info "ERROR: #{e.message}"
        log_notice "   ---> FAILURE: HOST TEST    [#{name}]"
        MRO.dump event: "build-failed", path: path
        raise
    end
    private :run_on_host

    def variants(options = {})
        v = ""
        v << " #{@options[:toolchain_version]}" unless @options[:toolchain_version].nil?
        v << " +PIE" if options[:pie]
        v
    end
    private :variants

    def build(options = {})
        log_notice "BLD #{@display_type} [#{name}]#{variants(options)}"

        dstdir = tmpdir(pie: options[:pie])

        FileUtils.rm_rf dstdir
        FileUtils.mkdir_p File.dirname(dstdir)
        FileUtils.cp_r path, dstdir

        FileUtils.cd(dstdir) do
            if has_cmakelists? && !has_build_script?
                cmakelists = File.read(File.join(path, 'CMakeLists.txt'))
                File.open(File.join(dstdir, 'CMakeLists.txt'), 'w') do |bf|
                    bf.puts "cmake_minimum_required(VERSION #{CMAKE_MINIMUM_VERSION} FATAL_ERROR)" if cmakelists.split("\n").select { |line| line =~ /^\s*cmake_minimum_required\s*\(/i }.empty?
                    bf.puts ''
                    bf.write cmakelists

                    if cmakelists.split("\n").reject { |line| line =~ /^\s*(#|$)/ }.first =~ /^\s*set\s*\(\s*TARGET\b/i
                        bf.puts ''
                        bf.puts 'install(TARGETS ${TARGET}'
                        bf.puts '        RUNTIME DESTINATION ${CMAKE_INSTALL_PREFIX}/bin'
                        bf.puts '        LIBRARY DESTINATION ${CMAKE_INSTALL_PREFIX}/lib'
                        bf.puts ')'
                        bf.puts 'foreach(__extLibrary ${ANDROID_PREBUILT_LIBRARIES})'
                        bf.puts '    install(FILES ${__extLibrary} DESTINATION ${CMAKE_INSTALL_PREFIX}/lib)'
                        bf.puts 'endforeach()'
                    end
                end

                File.open(File.join(dstdir, 'build.sh'), 'w') do |bf|
                    bf.puts '#!/bin/sh'
                    bf.puts 'run()'
                    bf.puts '{'
                    bf.puts '    echo "## COMMAND: $@"'
                    bf.puts '    "$@"'
                    bf.puts '}'

                    args = []
                    args << "-DCMAKE_TOOLCHAIN_FILE=#{File.join(@ndk, 'cmake', 'toolchain.cmake')}"
                    args << "-DANDROID_TOOLCHAIN_VERSION=#{@options[:toolchain_version]}" unless @options[:toolchain_version].nil?
                    args << "-DANDROID_APP_PIE=#{options[:pie]}" unless options[:pie].nil?

                    %w[armeabi armeabi-v7a armeabi-v7a-hard x86 mips arm64-v8a x86_64 mips64].each do |abi|
                        blddir = File.join(dstdir, 'cmake-build', abi)
                        tmpinstalldir = File.join(dstdir, 'cmake-install', abi)
                        installdir = File.join(dstdir, 'libs', abi)

                        aargs = args.dup
                        aargs << "-DCMAKE_INSTALL_PREFIX=#{tmpinstalldir}"
                        aargs << "-DANDROID_ABI=#{abi}"

                        bf.puts "run rm -Rf #{blddir} #{tmpinstalldir} #{installdir} || exit 1"
                        bf.puts "run mkdir -p #{blddir} || exit 1"
                        bf.puts "run cd #{blddir} || exit 1"
                        bf.puts "run #{cmake} #{aargs.join(' ')} #{dstdir} || exit 1"
                        bf.puts "run #{gnumake} -j#{@jobs} VERBOSE=1 || exit 1"
                        bf.puts "run #{gnumake} install VERBOSE=1 || exit 1"
                        bf.puts "for f in `ls -1 #{tmpinstalldir}/bin/ 2>/dev/null` `ls -1 #{tmpinstalldir}/lib/lib*.so 2>/dev/null`; do"
                        bf.puts "    mkdir -p #{installdir} || exit 1"
                        bf.puts "    run cp $f #{installdir}/ || exit 1"
                        bf.puts "done"
                    end
                    bf.puts "exit 0"
                end
                FileUtils.chmod 0755, File.join(dstdir, 'build.sh') unless WINDOWS
            end

            bs = nil
            [
                File.join(dstdir, 'build.sh'),
                @ndkbuild,
            ].each do |bf|
                next unless File.send(WINDOWS ? 'exists?' : 'executable?', bf)
                bs = bf
                break
            end

            raise "Don't know how to build project #{name}" if bs.nil?

            env = {}
            env['V'] = '1'
            env['APP_PIE'] = (options[:pie] ? true : false).to_s
            env['GNUMAKE'] = gnumake
            env['JOBS'] = @jobs

            args = [bs]
            if bs == @ndkbuild
                args << "-B"
                args << "-j#{@jobs}"
                env.each do |k,v|
                    args << "#{k}=#{v}"
                end
            end

            cmd = args.join(' ')
            if WINDOWS && bs != @ndkbuild
                shell = ENV['SHELL']
                if ENV['OSTYPE'] == 'cygwin'
                    o,e,s = Open3.capture3("cygpath -m #{shell}")
                    raise "Can't convert cygwin path to native: #{e}" unless s.success?
                    shell = o.chomp
                else
                    shell = shell.sub(/^\/([A-Za-z])\//, '\1:/')
                end
                cmd = "#{shell} #{cmd}"
            end

            max_attempts = 5
            attempt = 1
            begin
                run_cmd cmd, env: env, errmsg: "Build of project #{name} failed", track_mkdir_errors: true
            rescue MkdirFailed
                attempt += 1
                raise "Build of project #{name} failed" if attempt > max_attempts
                log_info "WARNING: Build of '#{name}' failed due to 'mkdir' error; trying again (attempt ##{attempt})"
                retry
            end
        end

        MRO.dump event: "build-success", path: path, pie: options[:pie]
    rescue => e
        log_info "ERROR: #{e.message}"
        log_notice "   ---> FAILURE: TARGET BUILD [#{name}]"
        MRO.dump event: "build-failed", path: path, pie: options[:pie]
        raise
    end
    private :build

    def run_on_device(options = {})
        abi = options[:abi]
        pie = options[:pie]

        dstdir = tmpdir(pie: pie)

        logprefix = "#{@display_type} [#{name}]#{variants(options)}"

        binaries = Dir.glob(File.join(dstdir, 'libs', abi, '*')).sort
        executables = binaries.reject { |e| e =~ /\.so$/ }

        broken = @properties['broken-run']
        broken = [broken] unless broken.is_a?(Array)
        executables.select! { |e| !broken.include?(File.basename(e)) }

        if executables.empty?
            log_notice "SKP #{logprefix}: no #{abi} binaries"
            return
        end

        logprefix << ": #{abi}"

        log_notice "BEG #{logprefix}"

        fields = {path: path, name: name, abi: abi}

        objdirs = [
            File.join(@ndk, 'sources', 'crystax', 'libs', abi),
            File.join(dstdir, 'obj', 'local', abi),
        ].select { |e| File.directory?(e) }

        cmdslist = File.join(dstdir, "executables-#{abi}.txt")
        FileUtils.mkdir_p File.dirname(cmdslist)
        File.open(cmdslist, "w") do |f|
            executables.each do |e|
                eopts = @properties['adbrunner-options'][File.basename(e)] rescue nil?
                eopts = {} unless eopts.is_a?(Hash)

                line = e.dup
                line << " ADBRUNNER-OPTIONS:#{eopts.to_json}" unless eopts.empty?

                f.puts line
            end
        end

        mroprefix = "CRYSTAX-MRO-#{SecureRandom.uuid.gsub('-', '')}"

        args = []
        args << "ruby"
        #args << File.join(@ndk, 'prebuilt', hosttag, 'bin', 'ruby')
        args << File.join(@ndk, 'tools', 'adbrunner')
        args << "--verbose"
        args << "--keep-going" if @options[:keep_going]
        args << "--no-print-timestamps"
        args << "--adb=#{@adb}" unless @adb.nil?
        args << "--ndk=#{@ndk}"
        args << "--abi=#{abi}"
        args << "--timeout=#{@stimeout}"
        args << "--emulator-tag=#{@emutag}" if !@emutag.nil?
        args << "--device-path=/data/local/tmp/ndk-tests"
        args << "--run-on-all-devices"
        if pie
            args << "--pie"
        else
            args << "--no-pie"
        end
        args << "--mro-prefix=#{mroprefix}"
        args << "--symbols-directories=#{objdirs.join(',')}"
        args << "--ld-library-path=#{File.join(dstdir, 'libs', abi)}"
        args << "@#{cmdslist}"

        env = {}

        skipreason = nil

        run_cmd args.join(' '), env: env, errmsg: "Test #{name} failed", mroprefix: mroprefix do |obj|
            case obj["event"]
            when "skip"
                num = obj["number"].to_i
                total = obj["total"].to_i
                w = total.to_s.length
                cnt = "%#{w}d/%#{w}d" % [num, total]
                # Log only first SKIP event
                log_notice "SKP #{logprefix} [#{cnt}] #{obj["reason"]}" #if obj["reason"] != skipreason
            when "run"
                num = obj["number"].to_i
                total = obj["total"].to_i
                w = total.to_s.length
                cnt = "%#{w}d/%#{w}d" % [num, total]
                log_notice "RUN #{logprefix} [#{cnt}] android-#{obj["apilevel"]} '#{obj["devmodel"]}'"
            when "fail"
                exe = obj["exe"]
                argv = obj["args"]
                rc = obj["exitcode"]
                log_notice "   ---> FAILURE: TARGET TEST  [#{name}] \"#{([File.basename(exe)] + argv).join(' ')}\": $?=#{rc}"
            when "pause"
                log_notice "RUN #{logprefix} [paused]"
            when "timeout"
                log_notice "   ---> FAILURE: TARGET TEST  [#{name}] TIMEOUT: #{obj["timeout"]} seconds"
            end

            skipreason = obj["event"] == "skip" ? obj["reason"] : nil
        end

        MRO.dump fields.merge({event: "test-success", pie: pie})
    rescue => e
        log_info "ERROR: #{e.message}"
        MRO.dump fields.merge({event: "test-failed", pie: pie})
        raise
    end
    private :run_on_device

    def test
        if broken?
            log_notice "SKP #{@display_type} [#{name}]: no build for #{@options[:toolchain_version]}"
            return
        end

        if long? && !@options[:full_testing] && (@options[:tests].nil? || !@options[:tests].include?(name))
            log_notice "SKP #{@display_type} [#{name}]: this is long test, but we're running in quick mode"
            return
        end

        run_on_host

        fails = 0

        pies = []
        if @options[:pie].nil?
            pies << false if @type == 'device'
            pies << true
        else
            pies << @options[:pie]
        end

        # clang don't support non-PIE binaries
        pies.select! { |p| p } if @options[:toolchain_version].to_s =~ /^clang/
        pies << true if pies.empty?

        pies.each do |pie|
            begin
                build pie: pie
            rescue => err
                raise unless @options[:keep_going]
                fails += 1
            end

            next if @type != 'device'

            Dir.glob(File.join(tmpdir(pie: pie), 'libs', '*'))
                .select { |e| File.directory?(e) }
                .map { |e| File.basename(e) }
                .sort
                .each do |abi|
                    next if !@abis.nil? && !@abis.include?(abi)
                    # 64-bit targets don't support non-PIE executables
                    next if !pie && ['arm64-v8a', 'x86_64', 'mips64'].include?(abi)
                    # clang have problems with 'armeabi' support
                    next if abi == 'armeabi' && @options[:toolchain_version].to_s =~ /^clang/

                    begin
                        run_on_device abi: abi, pie: pie
                    rescue => err
                        raise unless @options[:keep_going]
                        fails += 1
                    end
            end
        end

        raise "Testing of #{name} failed" if fails > 0
    end
end
