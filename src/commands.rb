require_relative './pipeline_renderer'
require_relative './command'
require_relative './docker'

def upload_pipeline(context)
  yml = PipelineRenderer.new(context).render!
  res = Command.new("buildkite-agent", "pipeline", "upload").with_stdin([yml]).run!.raise!

  if res.success?
    puts "Successfully uploaded pipeline"
  end
end

def test_project(context, project, connector)
  DockerCommands.kill_all
  DockerCommands.run_tests_for(context, project, connector)
end

def test_rust(context)
  DockerCommands.kill_all
  DockerCommands.run_rust_tests(context)
end

def connector_test_kit(context, connector)
  DockerCommands.kill_all
  DockerCommands.run_connector_test_kit(context, connector)
end

def build_images(context, tag)
  DockerCommands.kill_all
  raise "Invalid version to build images from." if tag.nil?

  tags_to_build = [tag.stringify]
  tags_to_build.push(infer_additional_tags(context, tag))

  DockerCommands.build(context, tag)
  DockerCommands.tag_and_push(context, tags_to_build.flatten.compact)

  # Because buildkite doesn't give us the underlying branch on a tagged build, we need to infer it.
  if context.tag.nil? || !context.tag.stable?
    trigger_dependent_pipeline(context.branch, tags_to_build)
  elsif context.tag.stable?
    trigger_dependent_pipeline("master", tags_to_build)
  end
end

def native_image(context, target, version_str)
  parsed_version = Tag.new(version_str)
  artifact_s3_paths = ["s3://#{ENV["GRAAL_ARTIFACT_BUCKET"]}/#{context.branch}/#{target}/#{context.commit}"]

  if parsed_version.stable?
    version_to_build = [version_str, infer_additional_tags(context, parsed_version)].flatten.compact.find do |version|
      # Always use the long version (x.y.z)
      /\d*(\.\d*){2}/.match(version)
    end

    # Also store as latest
    artifact_s3_paths.push "s3://#{ENV["GRAAL_ARTIFACT_BUCKET"]}/#{context.branch}/#{target}/latest"
  elsif context.branch == "alpha" || context.branch == "beta"
    version_to_build = version_str
    artifact_s3_paths.push "s3://#{ENV["GRAAL_ARTIFACT_BUCKET"]}/#{context.branch}/#{target}/latest"
  else
    version_to_build = version_str
  end

  # Produces a binary in the target folder
  DockerCommands.native_image(context, version_to_build, "build-image:#{target}")
  Dir.chdir("#{context.server_root_path}/images/prisma-native/target/prisma-native-image") # Necessary to keep the buildkite agent from prefixing the binary when uploading

  artifact_s3_paths.each do |path|
    Command.new("buildkite-agent", "artifact", "upload", "prisma-native").with_env({
      "BUILDKITE_ARTIFACT_UPLOAD_DESTINATION" => path
    }).puts!.run!.raise!
  end
end

def rust_binary(context, platform)
  # Artifact whitelist. All named will be zipped and uploaded
  upload_artifacts = ["prisma", "migration-engine", "prisma-fmt"]

  # Upload folder paths in s3
  artifact_paths = []

  if platform == "alpine"
    artifact_paths.push(artifact_paths_for(context, "linux-musl-libssl1.1.0"))
    DockerCommands.rust_binary_musl(context)
    Dir.chdir("#{context.server_root_path}/prisma-rs/target/x86_64-unknown-linux-musl/release") # Necessary to keep the buildkite agent from prefixing the binary when uploading

  elsif platform == "debian"
    artifact_paths.push(artifact_paths_for(context, "linux-glibc-libssl1.1.0"))
    DockerCommands.rust_binary(context)
    Dir.chdir("#{context.server_root_path}/prisma-rs/target/release") # Necessary to keep the buildkite agent from prefixing the binary when uploading

  elsif platform == "zeit"
    artifact_paths.push(artifact_paths_for(context, "linux-glibc-libssl1.0.1"))
    DockerCommands.rust_binary_zeit(context)
    Dir.chdir("#{context.server_root_path}/prisma-rs/target/release") # Necessary to keep the buildkite agent from prefixing the binary when uploading

  elsif platform == "lambda"
    artifact_paths.push(artifact_paths_for(context, "linux-glibc-libssl1.0.2"))
    DockerCommands.rust_binary_lambda(context)
    Dir.chdir("#{context.server_root_path}/prisma-rs/target/release") # Necessary to keep the buildkite agent from prefixing the binary when uploading

  elsif platform == "native"
    artifact_paths.push(artifact_paths_for(context, "darwin"))
    puts "Updating rust..."
    Command.new("rustup", "update").puts!.run!.raise!

    puts "Cleaning up..."
    Command.new("cargo", "clean", "--manifest-path=#{context.server_root_path}/prisma-rs/Cargo.toml").puts!.run!.raise!

    puts "Building..."
    Command.new("cargo", "build", "--manifest-path=#{context.server_root_path}/prisma-rs/Cargo.toml", "--release").puts!.run!.raise!
    Dir.chdir("#{context.server_root_path}/prisma-rs/target/release") # Necessary to keep the buildkite agent from prefixing the binary when uploading

  elsif platform == "windows"
    artifact_paths.push(artifact_paths_for(context, "windows"))
    DockerCommands.rust_binary_windows(context)
    Dir.chdir("#{context.server_root_path}/prisma-rs/target/x86_64-pc-windows-gnu/release") # Necessary to keep the buildkite agent from prefixing the binary when uploading
  else
    raise "Unsupported platform #{platform}"
  end

  # Gzip all artifacts
  upload_artifacts.each do |upload_artifact|
    Command.new('gzip', '-f', upload_artifact).puts!.run!.raise!
  end

  artifact_paths.flatten.each do |path|
    upload_artifacts.each do |upload_artifact|
      Command.new("buildkite-agent", "artifact", "upload", "#{upload_artifact}.gz").with_env({
        "BUILDKITE_S3_DEFAULT_REGION" => "eu-west-1",
        "BUILDKITE_ARTIFACT_UPLOAD_DESTINATION" => path
      }).puts!.run!.raise!
    end
  end
end

# Builds s3 folder path based on context.
def artifact_paths_for(context, target_name)
  artifact_s3_paths = ["s3://#{ENV["RUST_ARTIFACT_BUCKET"]}/#{context.branch}/#{context.commit}/#{target_name}"]

  if context.branch == "alpha" || context.branch == "beta" || (!context.tag.nil? && (context.tag.stable? || context.tag.beta?))
    artifact_s3_paths.push "s3://#{ENV["RUST_ARTIFACT_BUCKET"]}/#{context.branch}/latest/#{target_name}"
  end

  artifact_s3_paths
end

def trigger_dependent_pipeline(channel, tags)
  pipeline_input = <<~EOS
    - trigger: \"prisma-cloud\"
      label: \":cloud: Trigger Prisma Cloud Tasks #{tags.join(", ")} :cloud:\"
      async: true
      build:
        env:
            BUILD_TAGS: \"#{tags.join(',')}\"
            CHANNEL: \"#{channel}\"
  EOS

  res = Command.new("buildkite-agent", "pipeline", "upload").with_stdin([pipeline_input]).run!.raise!
end

def infer_additional_tags(context, tag)
  additional_tags = []

  unless tag.nil?
    if tag.stable? || tag.beta?
      if tag.patch.nil?
        # E.g. not only tag 1.30(-beta), but also 1.30.0(-beta)
        additional_tag = tag.dup
        additional_tag.patch = 0
        additional_tags.push additional_tag.stringify
      else
        # E.g. not only tag 1.30.0(-beta), but also 1.30(-beta)
        additional_tag = tag.dup
        additional_tag.patch = nil
        additional_tags.push additional_tag.stringify
      end
    else
      if tag.revision.nil?
        # E.g. not only tag 1.30-beta, but also 1.30-beta-1
        additional_tag = tag.dup
        additional_tag.revision = 1
        additional_tags.push additional_tag.stringify
      else
        # E.g. not only tag 1.30-beta-1, but also 1.30-beta
        additional_tag = tag.dup
        additional_tag.revision = nil
        additional_tags.push additional_tag.stringify
      end
    end
  end

  additional_tags
end

# Eliminates consistency issues on buildkite
def git_fetch
  Command.new("git", "fetch", "--tags", "-f").run!.raise!
end