module Refinery
  module ExtensionGeneration

    def self.included(base)
      base.class_eval do
        argument :attributes, :type => :array, :default => [], :banner => "field:type field:type"

        class_option :namespace, :type => :string, :default => nil, :banner => 'NAMESPACE', :required => false
        class_option :extension, :type => :string, :default => nil, :banner => 'ENGINE', :required => false
        class_option :i18n, :type => :array, :default => [], :required => false, :banner => "field field", :desc => 'Indicates generated fields'
        class_option :install, :type => :boolean, :default => false, :required => false, :banner => nil, :desc => 'Bundles and runs the generated generator, rake db:migrate, rake db:seed for you'

        remove_class_option :skip_namespace
      end
    end

    def namespacing
      @namespacing ||= if options[:namespace].present?
        # Use exactly what the user requested, not a pluralised version.
        options[:namespace].to_s.camelize
      else
        # If the user has passed an engine, we want to generate it inside of
        # that extension.
        if options[:extension].present?
          options[:extension].to_s.camelize
        else
          class_name.pluralize
        end
      end
    end

    def extension_name
      @extension_name ||= options[:extension].presence || singular_name
    end

    def extension_class_name
      @extension_class_name ||= extension_name.camelize
    end

    def extension_plural_class_name
      @extension_plural_class_name ||= if options[:extension].present?
        # Use exactly what the user requested, not a plural version.
        extension_class_name
      else
        extension_class_name.pluralize
      end
    end

    def extension_plural_name
      @extension_plural_name ||= if options[:extension].present?
        # Use exactly what the user requested, not a plural version.
        extension_name
      else
        extension_name.pluralize
      end
    end

    def localized?
      localized_attributes.any?
    end

    def localized_attributes
      @localized_attributes ||= attributes.select{|a| options[:i18n].include?(a.name)}
    end

    def attributes_for_translation_table
      localized_attributes.inject([]) {|memo, attr| memo << ":#{attr.name} => :#{attr.type}"}.join(', ')
    end

    def string_attributes
      @string_attributes ||= attributes.select {|a| /string|text/ === a.type.to_s}.uniq
    end

    def image_attributes
      @image_attributes ||= attributes.select { |a| a.type == :image }.uniq
    end

    def resource_attributes
      @resource_attributes ||= attributes.select { |a| a.type == :resource }.uniq
    end

    def names_for_attr_accessible
      @attributes_for_attr_accessible ||= attributes.map do |a|
        case a.type
        when :image, :resource
          "#{a.name}_id" unless a.name[-3..-1] == "_id"
        else
          a.name
        end
      end
    end

    protected

    def append_extension_to_gemfile!
      unless Rails.env.test? || (self.behavior != :revoke && extension_in_gemfile?)
        path = extension_pathname.parent.relative_path_from(gemfile.parent)
        append_file gemfile, "\ngem '#{gem_name}', :path => '#{path}'"
      end
    end

    def clash_keywords
      @clash_keywords ||= begin
        clash_keywords = []
        unless (clash_file = source_pathname.parent.join('clash_keywords.yml')).file?
          clash_file = source_pathname.parent.parent.join('clash_keywords.yml')
        end
        clash_keywords = YAML.load_file(clash_file) if clash_file.file?
        clash_keywords
      end
    end

    def default_generate!
      sanity_check!

      evaluate_templates!

      unless options[:pretend]
        merge_locales!

        copy_or_merge_seeds!

        append_extension_to_gemfile!
      end

      install! if options[:install]

      finalize_extension!
    end

    def destination_pathname
      @destination_pathname ||= Pathname.new(self.destination_root.to_s)
    end

    def extension_pathname
      destination_pathname.join('vendor', 'extensions', extension_plural_name)
    end

    def extension_path_for(path, extension, apply_tmp = true)
      path = substitute_path_placeholders extension_pathname.join(
        path.to_s.gsub(%r{#{source_pathname}/?}, '')
      ).to_s

      if options[:namespace].present? || options[:extension].present?
        path = increment_migration_timestamp(path)

        # Detect whether this is a special file that needs to get merged not overwritten.
        # This is important only when nesting extensions.
        # Routes and #{gem_name}\.rb have an .erb extension as path points to the generator template
        # We have to exclude it when checking if the file already exists and  include it in the regexps
        path = extension_path_for_nested_extension(path, apply_tmp) if extension.present?
      end

      path.present? ? Pathname.new(path) : path
    end

    def erase_destination!
      if Pathname.glob(extension_pathname.join('**', '*')).all?(&:directory?)
        say_status :remove, relative_to_original_destination_root(extension_pathname.to_s), true
        FileUtils.rm_rf extension_pathname unless options[:pretend]
      end
    end

    def evaluate_templates!
      viable_templates.each do |source_path, destination_path|
        next if /seeds.rb.erb/ === source_path.to_s

        destination_path.sub!('.erb', '') if source_path.to_s !~ /views/

        template source_path, destination_path
      end
    end

    def existing_extension?
      options[:extension].present? && extension_pathname.directory?
    end

    def exit_with_message!(message)
      STDERR.puts "\n#{message}\n\n"
      exit 1
    end

    def extension_in_gemfile?
      gemfile.read.scan(%r{#{gem_name}}).any?
    end

    def finalize_extension!
      if self.behavior != :revoke && !self.options['pretend']
        instruct_user!
      else
        erase_destination!
      end
    end

    def gem_name
      "refinerycms-#{extension_plural_name}"
    end

    def gemfile
      @gemfile ||= begin
        Bundler.default_gemfile || destination_pathname.join('Gemfile')
      end
    end

    def generator_command
      raise "You must override the method 'generator_command' in your generator."
    end

    def install!
      run "bundle install"
      run "rails generate refinery:#{extension_plural_name}"
      run "rake db:migrate"
      run "rake db:seed"
    end

    def merge_locales!
      if existing_extension?
        # go through all of the temporary files and merge what we need into the current files.
        tmp_directories = []
        Dir.glob(source_pathname.join("{config/locales/*.yml,config/routes.rb.erb,lib/refinerycms-extension_plural_name.rb.erb}"), File::FNM_DOTMATCH).sort.each do |path|
          # get the path to the current tmp file.
          # Both the new and current paths need to strip the .erb portion from the generator template
          new_file_path = Pathname.new extension_path_for(path, extension_name).to_s.gsub(/\.erb$/, "")
          tmp_directories << Pathname.new(new_file_path.to_s.split(File::SEPARATOR)[0..-2].join(File::SEPARATOR)) # save for later
          # get the path to the existing file and perform a deep hash merge.
          current_path = Pathname.new extension_path_for(path, extension_name, false).to_s.gsub(/\.erb$/, "")
          new_contents = nil

          if File.exist?(new_file_path) && %r{.yml$} === new_file_path.to_s
            # merge translation files together.
            new_contents = YAML::load(new_file_path.read).deep_merge(
              YAML::load(current_path.read)
            ).to_yaml.gsub(%r{^---\n}, '')
          elsif %r{/routes.rb$} === new_file_path.to_s
            # append any routes from the new file to the current one.
            routes_file = [(file_parts = current_path.read.to_s.split("\n")).first]
            routes_file += file_parts[1..-2]
            routes_file += new_file_path.read.to_s.split("\n")[1..-2]
            routes_file << file_parts.last
            new_contents = routes_file.join("\n")
          elsif %r{/#{gem_name}.rb$} === new_file_path.to_s
            new_contents = current_path.read + new_file_path.read
          end
          # write to current file the merged results.
          current_path.open('w+') { |file| file.puts new_contents } if new_contents
        end

        tmp_directories.uniq.each{|dir| remove_dir(dir) if dir && dir.exist?}
      end
    end

    def copy_or_merge_seeds!
      source_seed_file      = source_pathname.join("db/seeds.rb.erb")
      destination_seed_file = destination_pathname.join(
        extension_path_for(
          source_seed_file.to_s.sub(".erb", ""), extension_name
        )
      )

      if existing_extension?
        merge_seed!(source_seed_file, destination_seed_file)
      else
        template source_seed_file, destination_seed_file
      end
    end

    def instruct_user!
      unless Rails.env.test?
        puts "------------------------"
        if options[:install]
          puts "Your extension has been generated and installed."
        else
          puts "Now run:"
          puts "bundle install"
          puts "rails generate refinery:#{extension_plural_name}"
          puts "rake db:migrate"
          puts "rake db:seed"
        end
        puts "Please restart your rails server."
        puts "------------------------"
      end
    end

    def reject_file?(file)
      !localized? && file.to_s.include?('locale_picker')
    end

    def reject_template?(file)
      file.directory? || reject_file?(file)
    end

    def sanity_check!
      prevent_clashes!
      prevent_uncountability!
      prevent_empty_attributes!
      prevent_invalid_extension!
    end

    def source_pathname
      @source_pathname ||= Pathname.new(self.class.source_root.to_s)
    end

    private
    def extension_path_for_nested_extension(path, apply_tmp)
      return nil if !File.exist?(path.gsub(/\.erb$/, '')) &&
                    %r{readme.md|(lib/)?#{plural_name}.rb$} === path

      if apply_tmp && %r{(locales/.*\.yml)|((config/routes|#{gem_name})\.rb\.erb)$} === path
        return path.split(File::SEPARATOR).insert(-2, "tmp").join(File::SEPARATOR)
      end

      path
    end

    def increment_migration_timestamp(path)
      # Increment the migration file leading number
      # Only relevant for nested or namespaced extensions, where a previous migration exists
      return path unless %r{/migrate/\d+.*\.rb.erb\z} === path && last_migration_file(path)

      path.gsub(%r{\d+_}) { |m| "#{last_migration_file(path).match(%r{migrate/(\d+)_})[1].to_i + 1}_" }
    end

    def last_migration_file(path)
      Dir[
        destination_pathname.join(path.split(File::SEPARATOR)[0..-2].
                             join(File::SEPARATOR), '*.rb')
      ].sort.last
    end

    def merge_seed!(source, destination)
      # create temp seeds file
      tmp_seeds = destination_pathname.join(
        extension_path_for("tmp/seeds.rb", extension_name)
      )

      # copy/evaluate seeds template to temp file
      template source, tmp_seeds, :verbose => false

      # append temp seeds file content to extension seeds file
      destination.open('a+') { |file| file.puts tmp_seeds.read.to_s }

      # remove temp file
      FileUtils.rm_rf tmp_seeds
    end

    def prevent_clashes!
      if clash_keywords.member?(singular_name.downcase)
        exit_with_message!("Please choose a different name. The generated code would fail for class '#{singular_name}' as it conflicts with a reserved keyword.")
      end
    end

    def prevent_uncountability!
      if singular_name == plural_name
        message = if singular_name.singularize == singular_name
          "The extension name you specified will not work as the singular name is equal to the plural name."
        else
          "Please specify the singular name '#{singular_name.singularize}' instead of '#{plural_name}'."
        end
        exit_with_message! message
      end
    end

    def prevent_empty_attributes!
      if attributes.empty? && self.behavior != :revoke
        exit_with_message! "You must specify a name and at least one field." \
                           "\nFor help, run: #{generator_command}"
      end
    end

    def prevent_invalid_extension!
      if options[:extension].present? && !extension_pathname.directory?
        exit_with_message! "You can't use '--extension #{options[:extension]}' option because" \
                           " extension with name #{options[:extension]} doesn't exist."
      end
    end

    def substitute_path_placeholders(path)
      path.gsub('extension_plural_name', extension_plural_name).
           gsub('plural_name', plural_name).
           gsub('singular_name', singular_name).
           gsub('namespace', namespacing.underscore)
    end

    def viable_templates
      @viable_templates ||= begin
        Pathname.glob(source_pathname.join('**', '**')).
                 reject{|f| reject_template?(f) }.
                 inject({}) do |hash, path|
          if (destination_path = extension_path_for(path, extension_name)).present?
            hash[path.to_s] = destination_path.to_s
          end

          hash
        end
      end
    end

  end
end
