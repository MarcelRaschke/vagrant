# Copyright (c) HashiCorp, Inc.
# SPDX-License-Identifier: BUSL-1.1

require "digest/sha1"
require "pathname"
require "tempfile"
require "tmpdir"
require "webrick"

require "fake_ftp"

require File.expand_path("../../../../base", __FILE__)

require "vagrant/util/file_checksum"

describe Vagrant::Action::Builtin::BoxAdd, :skip_windows, :bsdtar do
  include_context "unit"

  let(:app) { lambda { |env| } }
  let(:env) { {
    box_collection: box_collection,
    hook: Proc.new { |name, env| env },
    tmp_path: Pathname.new(Dir.mktmpdir("vagrant-test-builtin-box-add")),
    ui: Vagrant::UI::Silent.new,
  } }

  subject { described_class.new(app, env) }

  let(:box_collection) { double("box_collection") }
  let(:iso_env) { isolated_environment }

  let(:box) do
    box_dir = iso_env.box3("foo", "1.0", :virtualbox)
    Vagrant::Box.new("foo", :virtualbox, "1.0", box_dir)
  end

  after do
    FileUtils.rm_rf(env[:tmp_path])
  end

  # Helper to quickly SHA1 checksum a path
  def checksum(path)
    FileChecksum.new(path, Digest::SHA1).checksum
  end

  def with_ftp_server(path, **opts)
    path = Pathname.new(path)

    port = nil
    server = nil
    with_random_port do |port1, port2|
      port = port1
      server = FakeFtp::Server.new(port1, port2)
    end
    server.add_file(path.basename.to_s, path.read)
    server.start
    yield port
  ensure
    server.stop rescue nil
  end

  def with_web_server(path, **opts)
    tf = Tempfile.new("vagrant-web-server")
    tf.close

    opts[:json_type] ||= "application/json"

    mime_types = WEBrick::HTTPUtils::DefaultMimeTypes
    mime_types.store "json", opts[:json_type]

    port   = 3838
    server = WEBrick::HTTPServer.new(
      AccessLog: [],
      Logger: WEBrick::Log.new(tf.path, 7),
      Port: port,
      DocumentRoot: path.dirname.to_s,
      MimeTypes: mime_types)
    thr = Thread.new { server.start }
    yield port
  ensure
    tf.unlink
    server.shutdown rescue nil
    thr.join rescue nil
  end

  before do
    allow(box_collection).to receive(:find).and_return(nil)
  end

  context "the download location is locked" do
    let(:box_path) { iso_env.box2_file(:virtualbox) }
    let(:mutex_path) {  env[:tmp_path].join("box" + Digest::SHA1.hexdigest("file://" + box_path.to_s) + ".lock").to_s }

    before do
      # Lock file
      @f = File.open(mutex_path, "w+") 
      @f.flock(File::LOCK_EX|File::LOCK_NB) 
    end
  
    after { @f.close }
    
    it "raises a download error" do
      env[:box_name] = "foo"
      env[:box_url] = box_path.to_s

      expect { subject.call(env) }.
        to raise_error(Vagrant::Errors::DownloadAlreadyInProgress)
    end
  end

  context "with box file directly" do
    it "adds it" do
      box_path = iso_env.box2_file(:virtualbox)

      env[:box_name] = "foo"
      env[:box_url] = box_path.to_s
      env[:box_architecture] = "x86_64"

      expect(box_collection).to receive(:add).with(any_args) { |path, name, version, opts|
        expect(checksum(path)).to eq(checksum(box_path))
        expect(name).to eq("foo")
        expect(version).to eq("0")
        expect(opts[:architecture]).to eq("x86_64")
        expect(opts[:metadata_url]).to be_nil
        true
      }.and_return(box)

      expect(app).to receive(:call).with(env)

      subject.call(env)
    end

    it "adds from multiple URLs" do
      box_path = iso_env.box2_file(:virtualbox)

      env[:box_name] = "foo"
      env[:box_url] = [
        "/foo/bar/baz",
        box_path.to_s,
      ]

      expect(box_collection).to receive(:add).with(any_args) { |path, name, version, opts|
        expect(checksum(path)).to eq(checksum(box_path))
        expect(name).to eq("foo")
        expect(version).to eq("0")
        expect(opts[:metadata_url]).to be_nil
        true
      }.and_return(box)

      expect(app).to receive(:call).with(env)

      subject.call(env)
    end

    it "adds from HTTP URL" do
      box_path = iso_env.box2_file(:virtualbox)
      with_web_server(box_path) do |port|
        env[:box_name] = "foo"
        env[:box_url] = "http://127.0.0.1:#{port}/#{box_path.basename}"

        expect(box_collection).to receive(:add).with(any_args) { |path, name, version, opts|
          expect(checksum(path)).to eq(checksum(box_path))
          expect(name).to eq("foo")
          expect(version).to eq("0")
          expect(opts[:metadata_url]).to be_nil
          true
        }.and_return(box)

        expect(app).to receive(:call).with(env)

        subject.call(env)
      end
    end

    it "adds from FTP URL" do
      box_path = iso_env.box2_file(:virtualbox)
      with_ftp_server(box_path) do |port|
        env[:box_name] = "foo"
        env[:box_url] = "ftp://127.0.0.1:#{port}/#{box_path.basename}"

        expect(box_collection).to receive(:add).with(any_args) { |path, name, version, opts|
          expect(checksum(path)).to eq(checksum(box_path))
          expect(name).to eq("foo")
          expect(version).to eq("0")
          expect(opts[:metadata_url]).to be_nil
          true
        }.and_return(box)

        expect(app).to receive(:call).with(env)

        subject.call(env)
      end
    end

    it "raises an error if no name is given" do
      box_path = iso_env.box2_file(:virtualbox)

      env[:box_url] = box_path.to_s

      expect(box_collection).to receive(:add).never
      expect(app).to receive(:call).never

      expect { subject.call(env) }.
        to raise_error(Vagrant::Errors::BoxAddNameRequired)
    end

    it "raises an error if the box already exists" do
      box_path = iso_env.box2_file(:virtualbox)

      env[:box_name] = "foo"
      env[:box_url] = box_path.to_s
      env[:box_provider] = "virtualbox"

      expect(box_collection).to receive(:find).with(
        "foo", ["virtualbox"], "0", nil).and_return(box)
      expect(box_collection).to receive(:add).never
      expect(app).to receive(:call).never

      expect { subject.call(env) }.
        to raise_error(Vagrant::Errors::BoxAlreadyExists)
    end

    it "raises an error if checksum specified and doesn't match" do
      box_path = iso_env.box2_file(:virtualbox)

      env[:box_name] = "foo"
      env[:box_url] = box_path.to_s
      env[:box_checksum] = checksum(box_path) + "A"
      env[:box_checksum_type] = "sha1"

      expect(box_collection).to receive(:add).never
      expect(app).to receive(:call).never

      expect { subject.call(env) }.
        to raise_error(Vagrant::Errors::BoxChecksumMismatch)
    end

    it "strips space if checksum specified ends or begins with blank space" do
      box_path = iso_env.box2_file(:virtualbox)

      box = double(
        name: "foo",
        version: "1.2.3",
        provider: "virtualbox",
      )

      env[:box_name] = "foo"
      env[:box_url] = box_path.to_s
      env[:box_checksum] = " #{checksum(box_path)} "
      env[:box_checksum_type] = "sha1"

      expect(box_collection).to receive(:add).and_return(box)

      expect { subject.call(env) }.to_not raise_error
    end

    it "ignores checksums if empty string" do
      box_path = iso_env.box2_file(:virtualbox)
      with_web_server(box_path) do |port|
        env[:box_name] = "foo"
        env[:box_url] = "http://127.0.0.1:#{port}/#{box_path.basename}"
        env[:box_checksum] = ""
        env[:box_checksum_type] = ""


        expect(box_collection).to receive(:add).with(any_args) { |path, name, version, opts|
          expect(checksum(path)).to eq(checksum(box_path))
          expect(name).to eq("foo")
          expect(version).to eq("0")
          expect(opts[:metadata_url]).to be_nil
          true
        }.and_return(box)

        expect(app).to receive(:call).with(env)

        subject.call(env)
      end
    end

    it "does not raise an error if the checksum has different case" do
      box_path = iso_env.box2_file(:virtualbox)

      box = double(
        name: "foo",
        version: "1.2.3",
        provider: "virtualbox",
      )

      env[:box_name] = box.name
      env[:box_url] = box_path.to_s
      env[:box_checksum] = checksum(box_path)
      env[:box_checksum_type] = "sha1"

      # Convert to a different case
      env[:box_checksum].upcase!

      expect(box_collection).to receive(:add).and_return(box)

      expect { subject.call(env) }.to_not raise_error
    end

    it "raises an error if the box path doesn't exist" do
      box_path = iso_env.box2_file(:virtualbox)

      env[:box_name] = "foo"
      env[:box_url] = box_path.to_s + "nope"

      expect(box_collection).to receive(:add).never
      expect(app).to receive(:call).never

      expect { subject.call(env) }.
        to raise_error(Vagrant::Errors::DownloaderError)
    end

    it "raises an error if a version was specified" do
      box_path = iso_env.box2_file(:virtualbox)

      env[:box_name] = "foo"
      env[:box_url] = box_path.to_s
      env[:box_version] = "1"

      expect(box_collection).to receive(:add).never

      expect(app).to receive(:call).never

      expect { subject.call(env) }.
        to raise_error(Vagrant::Errors::BoxAddDirectVersion)
    end

    it "force adds if exists and specified" do
      box_path = iso_env.box2_file(:virtualbox)

      env[:box_force] = true
      env[:box_name] = "foo"
      env[:box_url] = box_path.to_s
      env[:box_provider] = "virtualbox"

      allow(box_collection).to receive(:find).and_return(box)
      expect(box_collection).to receive(:add).with(any_args) { |path, name, version, opts|
        expect(checksum(path)).to eq(checksum(box_path))
        expect(name).to eq("foo")
        expect(version).to eq("0")
        expect(opts[:metadata_url]).to be_nil
        true
      }.and_return(box)
      expect(app).to receive(:call).with(env).once

      subject.call(env)
    end

    context "with a box name accidentally set as a URL" do
      it "displays a warning to the user" do
        box_path = iso_env.box2_file(:virtualbox)
        port = 9999

        box_url_name = "http://127.0.0.1:#{port}/#{box_path.basename}"
        env[:box_name] = box_url_name

        expect(box_collection).to receive(:add).with(any_args) { |path, name, version, opts|
          expect(name).to eq(box_url_name)
          expect(version).to eq("0")
          expect(opts[:metadata_url]).to be_nil
          true
        }.and_return(box)

        expect(app).to receive(:call).with(env)

        expect(env[:ui]).to receive(:warn).and_call_original
          .with(/It looks like you attempted to add a box with a URL for the name/)

        subject.call(env)
      end
    end

    context "with a box name containing invalid URI characters" do
      it "should not raise an error" do
        box_path = iso_env.box2_file(:virtualbox)
        box_url_name = "box name with spaces"
        env[:box_name] = box_url_name

        expect(box_collection).to receive(:add).with(any_args) { |path, name, version, opts|
          expect(name).to eq(box_url_name)
          expect(version).to eq("0")
          expect(opts[:metadata_url]).to be_nil
          true
        }.and_return(box)

        expect(app).to receive(:call).with(env)

        subject.call(env)
      end
    end

    context "with URL containing credentials" do
      let(:username){ "box-username" }
      let(:password){ "box-password" }

      it "scrubs credentials in output" do
        box_path = iso_env.box2_file(:virtualbox)
        with_web_server(box_path) do |port|
          env[:box_name] = "foo"
          env[:box_url] = "http://#{username}:#{password}@127.0.0.1:#{port}/#{box_path.basename}"

          expect(box_collection).to receive(:add).with(any_args) { |path, name, version, opts|
            expect(checksum(path)).to eq(checksum(box_path))
            expect(name).to eq("foo")
            expect(version).to eq("0")
            expect(opts[:metadata_url]).to be_nil
            true
          }.and_return(box)

          allow(env[:ui]).to receive(:detail).and_call_original
          expect(env[:ui]).to receive(:detail).with(%r{.*http://(?!#{username}).+?:(?!#{password}).+?@127\.0\.0\.1:#{port}/#{box_path.basename}.*}).
            and_call_original
          expect(app).to receive(:call).with(env)

          subject.call(env)
        end
      end
    end
  end

  context "with box metadata" do
    it "adds from HTTP URL" do
      box_path = iso_env.box2_file(:virtualbox)
      tf = Tempfile.new(["vagrant-test-box-http-url", ".json"]).tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5"
            },
            {
              "version": "0.7",
              "providers": [
                {
                  "name": "virtualbox",
                  "url":  "#{box_path}"
                }
              ]
            }
          ]
        }
        RAW
        f.close
      end

      md_path = Pathname.new(tf.path)
      with_web_server(md_path) do |port|
        env[:box_url] = "http://127.0.0.1:#{port}/#{md_path.basename}"

        expect(box_collection).to receive(:add).with(any_args) { |path, name, version, opts|
          expect(name).to eq("foo/bar")
          expect(version).to eq("0.7")
          expect(checksum(path)).to eq(checksum(box_path))
          expect(opts[:metadata_url]).to eq(env[:box_url])
          true
        }.and_return(box)

        expect(app).to receive(:call).with(env)

        subject.call(env)
      end
    end

    it "adds from HTTP URL with complex JSON mime type" do
      box_path = iso_env.box2_file(:virtualbox)
      tf = Tempfile.new(["vagrant-test-http-json", ".json"]).tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5"
            },
            {
              "version": "0.7",
              "providers": [
                {
                  "name": "virtualbox",
                  "url":  "#{box_path}"
                }
              ]
            }
          ]
        }
        RAW
        f.close
      end

      opts = { json_type: "application/json; charset=utf-8" }

      md_path = Pathname.new(tf.path)
      with_web_server(md_path, **opts) do |port|
        env[:box_url] = "http://127.0.0.1:#{port}/#{md_path.basename}"

        expect(box_collection).to receive(:add).with(any_args) { |path, name, version, opts|
          expect(name).to eq("foo/bar")
          expect(version).to eq("0.7")
          expect(checksum(path)).to eq(checksum(box_path))
          expect(opts[:metadata_url]).to eq(env[:box_url])
          true
        }.and_return(box)

        expect(app).to receive(:call).with(env)

        subject.call(env)
      end
    end

    it "adds from shorthand path" do
      box_path = iso_env.box2_file(:virtualbox)
      td = Pathname.new(Dir.mktmpdir("vagrant-test-box-add-shorthand-path"))
      tf = td.join("mitchellh", "precise64.json")
      tf.dirname.mkpath
      tf.open("w") do |f|
        f.write(<<-RAW)
        {
          "name": "mitchellh/precise64",
          "versions": [
            {
              "version": "0.5"
            },
            {
              "version": "0.7",
              "providers": [
                {
                  "name": "virtualbox",
                  "url":  "#{box_path}"
                }
              ]
            }
          ]
        }
        RAW
      end

      with_web_server(tf.dirname) do |port|
        url = "http://127.0.0.1:#{port}"
        env[:box_url] = "mitchellh/precise64.json"

        expect(box_collection).to receive(:add).with(any_args) { |path, name, version, opts|
          expect(name).to eq("mitchellh/precise64")
          expect(version).to eq("0.7")
          expect(checksum(path)).to eq(checksum(box_path))
          expect(opts[:metadata_url]).to eq(
            "#{url}/#{env[:box_url]}")
          true
        }.and_return(box)

        expect(app).to receive(:call).with(env)

        with_temp_env("VAGRANT_SERVER_URL" => url) do
          subject.call(env)
        end
      end

      FileUtils.rm_rf(td)
    end

    it "adds from API endpoint when available" do
      box_path = iso_env.box2_file(:virtualbox)
      td = Pathname.new(Dir.mktmpdir("vagrant-test-box-api-endpoint"))
      tf = td.join("mitchellh", "precise64.json")
      tf.dirname.mkpath
      tf.open("w") do |f|
        f.write(<<-RAW)
        {
          "name": "mitchellh/precise64",
          "versions": [
            {
              "version": "0.5"
            },
            {
              "version": "0.7",
              "providers": [
                {
                  "name": "virtualbox",
                  "url":  "#{box_path}"
                }
              ]
            }
          ]
        }
        RAW
      end
      apif = td.join("api", "v2", "vagrant", "mitchellh", "precise64.json")
      apif.dirname.mkpath
      apif.open("w") do |f|
        f.write(<<-RAW)
        {
          "name": "mitchellh/precise64",
          "versions": [
            {
              "version": "0.5"
            },
            {
              "version": "0.8",
              "providers": [
                {
                  "name": "virtualbox",
                  "url":  "#{box_path}"
                }
              ]
            }
          ]
        }
        RAW
      end

      with_web_server(tf.dirname) do |port|
        url = "http://127.0.0.1:#{port}"
        env[:box_url] = "mitchellh/precise64.json"
        env[:box_server_url] = url

        expect(box_collection).to receive(:add).with(any_args) { |path, name, version, opts|
          expect(name).to eq("mitchellh/precise64")
          expect(version).to eq("0.8")
          expect(checksum(path)).to eq(checksum(box_path))
          expect(opts[:metadata_url]).to eq(
            "#{url}/api/v2/vagrant/#{env[:box_url]}")
          true
        }.and_return(box)

        expect(app).to receive(:call).with(env)

        subject.call(env)
      end

      FileUtils.rm_rf(td)
    end

    it "add from shorthand path with configured server url" do
      box_path = iso_env.box2_file(:virtualbox)
      td = Pathname.new(Dir.mktmpdir("vagrant-test-box-add-server-url"))
      tf = td.join("mitchellh", "precise64.json")
      tf.dirname.mkpath
      tf.open("w") do |f|
        f.write(<<-RAW)
        {
          "name": "mitchellh/precise64",
          "versions": [
            {
              "version": "0.5"
            },
            {
              "version": "0.7",
              "providers": [
                {
                  "name": "virtualbox",
                  "url":  "#{box_path}"
                }
              ]
            }
          ]
        }
        RAW
      end

      with_web_server(tf.dirname) do |port|
        url = "http://127.0.0.1:#{port}"
        env[:box_url] = "mitchellh/precise64.json"
        env[:box_server_url] = url

        expect(box_collection).to receive(:add).with(any_args) { |path, name, version, opts|
          expect(name).to eq("mitchellh/precise64")
          expect(version).to eq("0.7")
          expect(checksum(path)).to eq(checksum(box_path))
          expect(opts[:metadata_url]).to eq(
            "#{url}/#{env[:box_url]}")
          true
        }.and_return(box)

        expect(app).to receive(:call).with(env)

        subject.call(env)
      end

      FileUtils.rm_rf(td)
    end

    it "authenticates HTTP URLs and adds them" do
      box_path = iso_env.box2_file(:virtualbox)
      tf = Tempfile.new(["vagrant-test-http", ".json"]).tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5"
            },
            {
              "version": "0.7",
              "providers": [
                {
                  "name": "virtualbox",
                  "url":  "bar"
                }
              ]
            }
          ]
        }
        RAW
        f.close
      end

      md_path = Pathname.new(tf.path)
      with_web_server(md_path) do |port|
        real_url = "http://127.0.0.1:#{port}/#{md_path.basename}"

        # Set the box URL to something fake so we can modify it in place
        env[:box_url] = "foo"

        env[:hook] = double("hook")

        expect(env[:hook]).to receive(:call).with(:authenticate_box_downloader, any_args).at_least(:once)

        allow(env[:hook]).to receive(:call).with(:authenticate_box_url, any_args).at_least(:once) do |name, opts|
          if opts[:box_urls] == ["foo"]
            next { box_urls: [real_url] }
          elsif opts[:box_urls] == ["bar"]
            next { box_urls: [box_path.to_s] }
          else
            raise "UNKNOWN: #{opts[:box_urls].inspect}"
          end
        end

        expect(box_collection).to receive(:add).with(any_args) { |path, name, version, opts|
          expect(name).to eq("foo/bar")
          expect(version).to eq("0.7")
          expect(checksum(path)).to eq(checksum(box_path))
          expect(opts[:metadata_url]).to eq("foo")
          true
        }.and_return(box)

        expect(app).to receive(:call).with(env)

        subject.call(env)
      end
    end

    it "authenticates HTTP URLs and adds them directly" do
      box_path = iso_env.box2_file(:virtualbox)
      tf = Tempfile.new(["vagrant-test-http", ".box"]).tap do |f|
        f.write()
        f.close
      end

      md_path = Pathname.new(tf.path)
      with_web_server(md_path) do |port|
        real_url = "http://127.0.0.1:#{port}/#{md_path.basename}"

        # Set the box URL to something fake so we can modify it in place
        env[:box_url] = "foo"
        env[:hook] = double("hook")
        env[:box_name] = "foo/bar"
        env[:box_provider] = "virtualbox"
        env[:box_checksum] = checksum(box_path)

        expect(env[:hook]).to receive(:call).with(:authenticate_box_downloader, any_args).at_least(:once)

        allow(env[:hook]).to receive(:call).with(:authenticate_box_url, any_args).at_least(:once) do |name, opts|
          if opts[:box_urls] == ["foo"]
            next { box_urls: [real_url] }
          else
            raise "UNKNOWN: #{opts[:box_urls].inspect}"
          end
        end

        expect(subject).to receive(:add_direct).with([real_url], anything)
        expect(app).to receive(:call).with(env)

        subject.call(env)
      end
    end

    it "adds from HTTP URL with a checksum" do
      box_path = iso_env.box2_file(:virtualbox)
      tf = Tempfile.new(["vagrant-test-http-checksum", ".json"]).tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5"
            },
            {
              "version": "0.7",
              "providers": [
                {
                  "name": "virtualbox",
                  "url":  "#{box_path}",
                  "checksum_type": "sha1",
                  "checksum": "#{checksum(box_path)}"
                }
              ]
            }
          ]
        }
        RAW
        f.close
      end

      md_path = Pathname.new(tf.path)
      with_web_server(md_path) do |port|
        env[:box_url] = "http://127.0.0.1:#{port}/#{md_path.basename}"

        expect(box_collection).to receive(:add).with(any_args) { |path, name, version, opts|
          expect(name).to eq("foo/bar")
          expect(version).to eq("0.7")
          expect(checksum(path)).to eq(checksum(box_path))
          expect(opts[:metadata_url]).to eq(env[:box_url])
          true
        }.and_return(box)

        expect(app).to receive(:call).with(env)

        subject.call(env)
      end
    end

    it "raises an exception if checksum given but not correct" do
      box_path = iso_env.box2_file(:virtualbox)
      tf = Tempfile.new(["vagrant-test-bad-checksum", ".json"]).tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5"
            },
            {
              "version": "0.7",
              "providers": [
                {
                  "name": "virtualbox",
                  "url":  "#{box_path}",
                  "checksum_type": "sha1",
                  "checksum": "thisisnotcorrect"
                }
              ]
            }
          ]
        }
        RAW
        f.close
      end

      md_path = Pathname.new(tf.path)
      with_web_server(md_path) do |port|
        env[:box_url] = "http://127.0.0.1:#{port}/#{md_path.basename}"

        expect(box_collection).to receive(:add).never
        expect(app).to receive(:call).never

        expect { subject.call(env) }.
          to raise_error(Vagrant::Errors::BoxChecksumMismatch)
      end
    end

    it "raises an error if no Vagrant server is set" do
      env[:box_url] = "mitchellh/precise64.json"

      expect(box_collection).to receive(:add).never
      expect(app).to receive(:call).never

      allow(Vagrant).to receive(:server_url).and_return(nil)

      expect { subject.call(env) }.
        to raise_error(Vagrant::Errors::BoxServerNotSet)
    end

    it "raises an error if shorthand is invalid" do
      path = Dir::Tmpname.create("vagrant-shorthand-invalid") {}

      with_web_server(Pathname.new(path)) do |port|
        env[:box_url] = "mitchellh/precise64.json"

        expect(box_collection).to receive(:add).never
        expect(app).to receive(:call).never

        url = "http://127.0.0.1:#{port}"
        with_temp_env("VAGRANT_SERVER_URL" => url) do
          expect { subject.call(env) }.
            to raise_error(Vagrant::Errors::BoxAddShortNotFound)
        end
      end
    end

    it "raises an error if downloading metadata fails" do
      path = Dir::Tmpname.create("vagrant-shorthand-invalid") {}

      with_web_server(Pathname.new(path)) do |port|
        env[:box_url] = "http://127.0.0.1:#{port}/bad"

        expect(box_collection).to receive(:add).never
        expect(app).to receive(:call).never

        expect { subject.call(env) }.
          to raise_error(Vagrant::Errors::BoxMetadataDownloadError)
      end
    end

    it "raises an error if multiple metadata URLs are given" do
      box_path = iso_env.box2_file(:virtualbox)
      tf = Tempfile.new(["vagrant-box-multi-metadata", ".json"]).tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5"
            },
            {
              "version": "0.7",
              "providers": [
                {
                  "name": "virtualbox",
                  "url":  "#{box_path}"
                }
              ]
            }
          ]
        }
        RAW
        f.close
      end

      env[:box_url] = [
        "/foo/bar/baz",
        tf.path,
      ]
      expect(box_collection).to receive(:add).never
      expect(app).to receive(:call).never

      expect { subject.call(env) }.
        to raise_error(Vagrant::Errors::BoxAddMetadataMultiURL)
    end

    it "adds the latest version of a box with only one provider" do
      box_path = iso_env.box2_file(:virtualbox)
      tf = Tempfile.new(["vagrant-box-latest-version", ".json"]).tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5"
            },
            {
              "version": "0.7",
              "providers": [
                {
                  "name": "virtualbox",
                  "url":  "#{box_path}"
                }
              ]
            }
          ]
        }
        RAW
        f.close
      end

      env[:box_url] = tf.path
      expect(box_collection).to receive(:add).with(any_args) { |path, name, version, opts|
        expect(checksum(path)).to eq(checksum(box_path))
        expect(name).to eq("foo/bar")
        expect(version).to eq("0.7")
        expect(opts[:metadata_url]).to eq("file://#{tf.path}")
        true
      }.and_return(box)

      expect(app).to receive(:call).with(env)

      subject.call(env)
    end

    context "with box architecture configured" do
      before do
        allow(Vagrant::Util::Platform).to receive(:architecture).and_return("test-arch")
      end

      context "set to :auto" do
        before do
          env[:box_architecture] = :auto
        end

        it "adds the latest version of a box with only one provider and matching architecture" do
          box_path = iso_env.box2_file(:virtualbox)
          tf = Tempfile.new(["vagrant-box-latest-version", ".json"]).tap do |f|
            f.write(
              {
                name: "foo/bar",
                versions: [
                  {
                    version: "0.5",
                  },
                  {
                    version: "0.7",
                    providers: [
                      {
                        name: "virtualbox",
                        url: "/dev/null/invalid.path",
                        architecture: "amd64",
                        default_architecture: true,
                      },
                      {
                        name: "virtualbox",
                        url: "#{box_path}",
                        architecture: "test-arch",
                        default_architecture: false,
                      }
                    ]
                  }
                ]
              }.to_json
            )
            f.close
          end

          env[:box_url] = tf.path
          expect(box_collection).to receive(:add).with(any_args) { |path, name, version, opts|
            expect(checksum(path)).to eq(checksum(box_path))
            expect(name).to eq("foo/bar")
            expect(version).to eq("0.7")
            expect(opts[:metadata_url]).to eq("file://#{tf.path}")
            expect(opts[:architecture]).to eq("test-arch")
            true
          }.and_return(box)

          expect(app).to receive(:call).with(env)

          subject.call(env)
        end

        it "adds the latest version of a box with multiple providers and only one provider matching architecture" do
          box_path = iso_env.box2_file(:virtualbox)
          tf = Tempfile.new(["vagrant-box-latest-version", ".json"]).tap do |f|
            # NOTE: The order of the providers here matters. The correct match needs
            # to be last in order to trigger the error this test was written for to
            # catch any regression.
            f.write(
              {
                name: "foo/bar",
                versions: [
                  {
                    version: "0.5",
                  },
                  {
                    version: "0.7",
                    providers: [
                      {
                        name: "virtualbox",
                        url: "/dev/null/invalid.path",
                        architecture: "amd64",
                        default_architecture: true,
                      },
                      {
                        name: "hyperv",
                        url: "#{box_path}",
                        architecture: "test-arch",
                        default_architecture: true,
                      }
                    ]
                  }
                ]
              }.to_json
            )
            f.close
          end

          env[:box_url] = tf.path
          expect(box_collection).to receive(:add).with(any_args) { |path, name, version, opts|
            expect(checksum(path)).to eq(checksum(box_path))
            expect(name).to eq("foo/bar")
            expect(version).to eq("0.7")
            expect(opts[:metadata_url]).to eq("file://#{tf.path}")
            expect(opts[:architecture]).to eq("test-arch")
            true
          }.and_return(box)

          expect(app).to receive(:call).with(env)

          subject.call(env)
        end

        it "adds the latest version of a box with only one provider and unknown architecture set as default" do
          box_path = iso_env.box2_file(:virtualbox)
          tf = Tempfile.new(["vagrant-box-latest-version", ".json"]).tap do |f|
            f.write(
              {
                name: "foo/bar",
                versions: [
                  {
                    version: "0.5",
                  },
                  {
                    version: "0.7",
                    providers: [
                      {
                        name: "virtualbox",
                        url: "#{box_path}",
                        architecture: "unknown",
                        default_architecture: true,
                      },
                      {
                        name: "virtualbox",
                        url: "/dev/null/invalid.path",
                        architecture: "amd64",
                        default_architecture: false,
                      }
                    ]
                  }
                ]
              }.to_json
            )
            f.close
          end

          env[:box_url] = tf.path
          expect(box_collection).to receive(:add).with(any_args) { |path, name, version, opts|
            expect(checksum(path)).to eq(checksum(box_path))
            expect(name).to eq("foo/bar")
            expect(version).to eq("0.7")
            expect(opts[:metadata_url]).to eq("file://#{tf.path}")
            expect(opts[:architecture]).to be_nil
            true
          }.and_return(box)

          expect(app).to receive(:call).with(env)

          subject.call(env)
        end

        it "errors adding latest version of a box with only one provider and no matching architecture" do
          allow(Vagrant::Util::Platform).to receive(:architecture).and_return("test-arch")

          box_path = iso_env.box2_file(:virtualbox)
          tf = Tempfile.new(["vagrant-box-latest-version", ".json"]).tap do |f|
            f.write(
              {
                name: "foo/bar",
                versions: [
                  {
                    version: "0.5",
                  },
                  {
                    version: "0.7",
                    providers: [
                      {
                        name: "virtualbox",
                        url: "#{box_path}",
                        architecture: "amd64",
                        default_architecture: true,
                      },
                      {
                        name: "virtualbox",
                        url: "/dev/null/invalid.path",
                        architecture: "arm64",
                        default_architecture: false,
                      }
                    ]
                  }
                ]
              }.to_json
            )
            f.close
          end

          env[:box_url] = tf.path

          expect {
            subject.call(env)
          }.to raise_error(Vagrant::Errors::BoxAddNoMatchingVersion)
        end
      end

      context "set to nil" do
        before do
          env[:box_architecture] = nil
        end

        it "adds the latest version of a box with only one provider and default architecture" do
          allow(Vagrant::Util::Platform).to receive(:architecture).and_return("default-arch")
          box_path = iso_env.box2_file(:virtualbox)
          tf = Tempfile.new(["vagrant-box-latest-version", ".json"]).tap do |f|
            f.write(
              {
                name: "foo/bar",
                versions: [
                  {
                    version: "0.5",
                  },
                  {
                    version: "0.7",
                    providers: [
                      {
                        name: "virtualbox",
                        url: "#{box_path}",
                        architecture: "default-arch",
                        default_architecture: true,
                      },
                      {
                        name: "virtualbox",
                        url: "/dev/null/invalid.path",
                        architecture: "test-arch",
                        default_architecture: false,
                      }
                    ]
                  }
                ]
              }.to_json
            )
            f.close
          end

          env[:box_url] = tf.path
          expect(box_collection).to receive(:add).with(any_args) { |path, name, version, opts|
            expect(checksum(path)).to eq(checksum(box_path))
            expect(name).to eq("foo/bar")
            expect(version).to eq("0.7")
            expect(opts[:metadata_url]).to eq("file://#{tf.path}")
            expect(opts[:architecture]).to eq("default-arch")
            true
          }.and_return(box)

          expect(app).to receive(:call).with(env)

          subject.call(env)
        end
      end

      context "set to explicit value" do
        before do
          env[:box_architecture] = "arm64"
        end

        it "adds the latest version of a box with only one provider and matching architecture" do
          box_path = iso_env.box2_file(:virtualbox)
          tf = Tempfile.new(["vagrant-box-latest-version", ".json"]).tap do |f|
            f.write(
              {
                name: "foo/bar",
                versions: [
                  {
                    version: "0.5",
                  },
                  {
                    version: "0.7",
                    providers: [
                      {
                        name: "virtualbox",
                        url: "#{box_path}",
                        architecture: "arm64",
                        default_architecture: false,
                      },
                      {
                        name: "virtualbox",
                        url: "/dev/null/invalid.path",
                        architecture: "test-arch",
                        default_architecture: true,
                      }
                    ]
                  }
                ]
              }.to_json
            )
            f.close
          end

          env[:box_url] = tf.path
          expect(box_collection).to receive(:add).with(any_args) { |path, name, version, opts|
            expect(checksum(path)).to eq(checksum(box_path))
            expect(name).to eq("foo/bar")
            expect(version).to eq("0.7")
            expect(opts[:metadata_url]).to eq("file://#{tf.path}")
            expect(opts[:architecture]).to eq("arm64")
            true
          }.and_return(box)

          expect(app).to receive(:call).with(env)

          subject.call(env)
        end

        it "errors adding the latest version of a box with only one provider and no matching architecture" do
          box_path = iso_env.box2_file(:virtualbox)
          tf = Tempfile.new(["vagrant-box-latest-version", ".json"]).tap do |f|
            f.write(
              {
                name: "foo/bar",
                versions: [
                  {
                    version: "0.5",
                  },
                  {
                    version: "0.7",
                    providers: [
                      {
                        name: "virtualbox",
                        url: "#{box_path}",
                        architecture: "amd64",
                        default_architecture: true,
                      },
                      {
                        name: "virtualbox",
                        url: "/dev/null/invalid.path",
                        architecture: "386",
                        default_architecture: false,
                      }
                    ]
                  }
                ]
              }.to_json
            )
            f.close
          end

          env[:box_url] = tf.path

          expect {
            subject.call(env)
          }.to raise_error(Vagrant::Errors::BoxAddNoMatchingVersion)
        end
      end
    end

    it "adds the latest version of a box with the specified provider" do
      box_path = iso_env.box2_file(:vmware)
      tf = Tempfile.new(["vagrant-box-specific-provider", ".json"]).tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5"
            },
            {
              "version": "0.7",
              "providers": [
                {
                  "name": "virtualbox",
                  "url":  "#{iso_env.box2_file(:virtualbox)}"
                },
                {
                  "name": "vmware",
                  "url":  "#{box_path}"
                }
              ]
            }
          ]
        }
        RAW
        f.close
      end

      env[:box_url] = tf.path
      env[:box_provider] = "vmware"
      expect(box_collection).to receive(:add).with(any_args) { |path, name, version, opts|
        expect(checksum(path)).to eq(checksum(box_path))
        expect(name).to eq("foo/bar")
        expect(version).to eq("0.7")
        expect(opts[:metadata_url]).to eq("file://#{tf.path}")
        true
      }.and_return(box)

      expect(app).to receive(:call).with(env)

      subject.call(env)

      expect(env[:box_added]).to equal(box)
    end

    it "adds the latest version of a box with the specified provider, even if not latest" do
      box_path = iso_env.box2_file(:vmware)
      tf = Tempfile.new(["vagrant-box-specified-provider", ".json"]).tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5"
            },
            {
              "version": "0.7",
              "providers": [
                {
                  "name": "virtualbox",
                  "url":  "#{iso_env.box2_file(:virtualbox)}"
                },
                {
                  "name": "vmware",
                  "url":  "#{box_path}"
                }
              ]
            },
            {
              "version": "1.5"
            }
          ]
        }
        RAW
        f.close
      end

      env[:box_url] = tf.path
      env[:box_provider] = "vmware"
      expect(box_collection).to receive(:add).with(any_args) { |path, name, version, opts|
        expect(checksum(path)).to eq(checksum(box_path))
        expect(name).to eq("foo/bar")
        expect(version).to eq("0.7")
        expect(opts[:metadata_url]).to eq("file://#{tf.path}")
        true
      }.and_return(box)

      expect(app).to receive(:call).with(env)

      subject.call(env)

      expect(env[:box_added]).to equal(box)
    end

    it "adds the constrained version of a box with the only provider" do
      box_path = iso_env.box2_file(:vmware)
      tf = Tempfile.new(["vagrant-box-constrained", ".json"]).tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5",
              "providers": [
                {
                  "name": "vmware",
                  "url":  "#{box_path}"
                }
              ]
            },
            { "version": "1.1" }
          ]
        }
        RAW
        f.close
      end

      env[:box_url] = tf.path
      env[:box_version] = "~> 0.1"
      expect(box_collection).to receive(:add).with(any_args) { |path, name, version, opts|
        expect(checksum(path)).to eq(checksum(box_path))
        expect(name).to eq("foo/bar")
        expect(version).to eq("0.5")
        expect(opts[:metadata_url]).to eq("file://#{tf.path}")
        true
      }.and_return(box)

      expect(app).to receive(:call).with(env)

      subject.call(env)

      expect(env[:box_added]).to equal(box)
    end

    it "adds the constrained version of a box with the specified provider" do
      box_path = iso_env.box2_file(:vmware)
      tf = Tempfile.new(["vagrant-box-constrained-provider", ".json"]).tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5",
              "providers": [
                {
                  "name": "vmware",
                  "url":  "#{box_path}"
                },
                {
                  "name": "virtualbox",
                  "url":  "#{iso_env.box2_file(:virtualbox)}"
                }
              ]
            },
            { "version": "1.1" }
          ]
        }
        RAW
        f.close
      end

      env[:box_url] = tf.path
      env[:box_provider] = "vmware"
      env[:box_version] = "~> 0.1"
      expect(box_collection).to receive(:add).with(any_args) { |path, name, version, opts|
        expect(checksum(path)).to eq(checksum(box_path))
        expect(name).to eq("foo/bar")
        expect(version).to eq("0.5")
        expect(opts[:metadata_url]).to eq("file://#{tf.path}")
        true
      }.and_return(box)

      expect(app).to receive(:call).with(env)

      subject.call(env)

      expect(env[:box_added]).to equal(box)
    end

    it "adds the latest version of a box with any specified provider" do
      box_path = iso_env.box2_file(:vmware)
      tf = Tempfile.new(["vagrant-box-latest-version", ".json"]).tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5",
              "providers": [
                {
                  "name": "virtualbox",
                  "url":  "#{iso_env.box2_file(:virtualbox)}"
                }
              ]
            },
            {
              "version": "0.7",
              "providers": [
                {
                  "name": "vmware",
                  "url":  "#{box_path}"
                }
              ]
            }
          ]
        }
        RAW
        f.close
      end

      env[:box_url] = tf.path
      env[:box_provider] = ["virtualbox", "vmware"]
      expect(box_collection).to receive(:add).with(any_args) { |path, name, version, opts|
        expect(checksum(path)).to eq(checksum(box_path))
        expect(name).to eq("foo/bar")
        expect(version).to eq("0.7")
        expect(opts[:metadata_url]).to eq("file://#{tf.path}")
        true
      }.and_return(box)

      expect(app).to receive(:call).with(env)

      subject.call(env)

      expect(env[:box_added]).to equal(box)
    end

    it "asks the user what provider if multiple options" do
      box_path = iso_env.box2_file(:virtualbox)
      tf = Tempfile.new(["vagrant-box-provider-asks", ".json"]).tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5"
            },
            {
              "version": "0.7",
              "providers": [
                {
                  "name": "virtualbox",
                  "url":  "#{box_path}"
                },
                {
                  "name": "vmware",
                  "url":  "#{iso_env.box2_file(:vmware)}"
                }
              ]
            }
          ]
        }
        RAW
        f.close
      end

      env[:box_url] = tf.path

      expect(env[:ui]).to receive(:ask).and_return("1")

      expect(box_collection).to receive(:add).with(any_args) { |path, name, version, opts|
        expect(checksum(path)).to eq(checksum(box_path))
        expect(name).to eq("foo/bar")
        expect(version).to eq("0.7")
        expect(opts[:metadata_url]).to eq("file://#{tf.path}")
        true
      }.and_return(box)

      expect(app).to receive(:call).with(env)

      subject.call(env)
    end

    it "raises an exception if the name doesn't match a requested name" do
      box_path = iso_env.box2_file(:virtualbox)
      tf = Tempfile.new(["vagrant-box-name-mismatch", ".json"]).tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5"
            },
            {
              "version": "0.7",
              "providers": [
                {
                  "name": "virtualbox",
                  "url":  "#{box_path}"
                }
              ]
            }
          ]
        }
        RAW
        f.close
      end

      env[:box_name] = "foo"
      env[:box_url] = tf.path

      expect(box_collection).to receive(:add).never
      expect(app).to receive(:call).never

      expect { subject.call(env) }.
        to raise_error(Vagrant::Errors::BoxAddNameMismatch)
    end

    it "raises an exception if no matching version" do
      box_path = iso_env.box2_file(:vmware)
      tf = Tempfile.new(["vagrant-box-no-matching-version", ".json"]).tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5",
              "providers": [
                {
                  "name": "vmware",
                  "url":  "#{box_path}"
                }
              ]
            },
            { "version": "1.1" }
          ]
        }
        RAW
        f.close
      end

      env[:box_url] = tf.path
      env[:box_version] = "~> 2.0"
      expect(box_collection).to receive(:add).never
      expect(app).to receive(:call).never

      expect { subject.call(env) }.
        to raise_error(Vagrant::Errors::BoxAddNoMatchingVersion)
    end

    it "raises an error if there is no matching provider" do
      tf = Tempfile.new(["vagrant-box-no-matching-provider", ".json"]).tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5"
            },
            {
              "version": "0.7",
              "providers": [
                {
                  "name": "virtualbox",
                  "url":  "#{iso_env.box2_file(:virtualbox)}"
                }
              ]
            }
          ]
        }
        RAW
        f.close
      end

      env[:box_url] = tf.path
      env[:box_provider] = "vmware"
      expect(box_collection).to receive(:add).never
      expect(app).to receive(:call).never

      expect { subject.call(env) }.
        to raise_error(Vagrant::Errors::BoxAddNoMatchingProvider)
    end

    it "raises an error if a box already exists" do
      box_path = iso_env.box2_file(:virtualbox)
      tf = Tempfile.new(["vagrant-box-already-exists", ".json"]).tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5"
            },
            {
              "version": "0.7",
              "providers": [
                {
                  "name": "virtualbox",
                  "url":  "#{box_path}"
                }
              ]
            }
          ]
        }
        RAW
        f.close
      end

      env[:box_url] = tf.path
      expect(box_collection).to receive(:find).
        with("foo/bar", "virtualbox", "0.7", nil).and_return(box)
      expect(box_collection).to receive(:add).never
      expect(app).to receive(:call).never

      expect { subject.call(env) }.
        to raise_error(Vagrant::Errors::BoxAlreadyExists)
    end

    it "force adds a box if specified" do
      box_path = iso_env.box2_file(:virtualbox)
      tf = Tempfile.new(["vagrant-box-force-add", ".json"]).tap do |f|
        f.write(<<-RAW)
        {
          "name": "foo/bar",
          "versions": [
            {
              "version": "0.5"
            },
            {
              "version": "0.7",
              "providers": [
                {
                  "name": "virtualbox",
                  "url":  "#{box_path}"
                }
              ]
            }
          ]
        }
        RAW
        f.close
      end

      env[:box_force] = true
      env[:box_url] = tf.path
      allow(box_collection).to receive(:find).and_return(box)
      expect(box_collection).to receive(:add).with(any_args) { |path, name, version, opts|
        expect(checksum(path)).to eq(checksum(box_path))
        expect(name).to eq("foo/bar")
        expect(version).to eq("0.7")
        expect(opts[:force]).to be(true)
        expect(opts[:metadata_url]).to eq("file://#{tf.path}")
        true
      }.and_return(box)

      expect(app).to receive(:call).with(env)

      subject.call(env)

      expect(env[:box_added]).to equal(box)
    end
  end

  describe "#downloader" do
    let(:options) { {} }

    after { subject.send(:downloader, url, env, **options) }

    context "when box is local" do
      let(:url) { "/dev/null/vagrant.box" }

      it "should prepend file protocol to path" do
        expect(Vagrant::Util::Downloader).to receive(:new) do |durl, *_|
          expect(durl).to eq("file://#{url}")
        end
      end
    end

    context "when box is remote" do
      let(:url) { "http://localhost/vagrant.box" }

      it "should not modify the url" do
        expect(Vagrant::Util::Downloader).to receive(:new) do |durl, *_|
          expect(durl).to eq(url)
        end
      end
    end

    context "when options are set in the environment" do
      let(:url) { "http://localhost/vagrant.box" }

      context "when ca cert value is set" do
        let(:ca_cert) { "/dev/null/ca.cert" }
        before { env[:box_download_ca_cert] = ca_cert }

        it "should include ca cert value" do
          expect(Vagrant::Util::Downloader).to receive(:new) do |_, _, opts|
            expect(opts[:ca_cert]).to eq(ca_cert)
          end
        end
      end

      context "when ca path value is set" do
        let(:ca_path) { "/dev/null/ca.path" }
        before { env[:box_download_ca_path] = ca_path }

        it "should include ca path value" do
          expect(Vagrant::Util::Downloader).to receive(:new) do |_, _, opts|
            expect(opts[:ca_path]).to eq(ca_path)
          end
        end
      end

      context "when insecure value is set" do
        before { env[:box_download_insecure] = true }

        it "should include insecure value" do
          expect(Vagrant::Util::Downloader).to receive(:new) do |_, _, opts|
            expect(opts[:insecure]).to be_truthy
          end
        end
      end

      context "when client cert value is set" do
        let(:client_cert_path) { "/dev/null/client.cert" }
        before { env[:box_download_client_cert] = client_cert_path }

        it "should include client cert value" do
          expect(Vagrant::Util::Downloader).to receive(:new) do |_, _, opts|
            expect(opts[:client_cert]).to eq(client_cert_path)
          end
        end
      end

      context "when location trusted is set" do
        before { env[:box_download_location_trusted] = true }

        it "should include client cert value" do
          expect(Vagrant::Util::Downloader).to receive(:new) do |_, _, opts|
            expect(opts[:location_trusted]).to be_truthy
          end
        end
      end

      context "when disable ssl revoke best effort is set" do
        before { env[:box_download_disable_ssl_revoke_best_effort] = true }

        it "should include disable revoke best effort value value" do
          expect(Vagrant::Util::Downloader).to receive(:new) do |_, _, opts|
            expect(opts[:disable_ssl_revoke_best_effort]).to be_truthy
          end
        end
      end
    end
  end
end
