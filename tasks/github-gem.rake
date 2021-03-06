require 'rubygems'
require 'rake'
require 'rake/tasklib'
require 'date'
require 'git'

module GithubGem
  
  def self.detect_gemspec_file
    FileList['*.gemspec'].first
  end
  
  def self.detect_main_include
    if detect_gemspec_file =~ /^(\.*)\.gemspec$/ && File.exist?("lib/#{$1}.rb")
      "lib/#{$1}.rb"
    elsif FileList['lib/*.rb'].length == 1
      FileList['lib/*.rb'].first
    else
      raise "Could not detect main include file!"
    end
  end
  
  class RakeTasks
    
    attr_reader   :gemspec, :modified_files, :git
    attr_accessor :gemspec_file, :task_namespace, :main_include, :root_dir, :spec_pattern, :test_pattern, :remote, :remote_branch, :local_branch
    
    def initialize(task_namespace = :gem)
      @gemspec_file   = GithubGem.detect_gemspec_file
      @task_namespace = task_namespace
      @main_include   = GithubGem.detect_main_include
      @modified_files = []
      @root_dir       = Dir.pwd
      @test_pattern   = 'test/**/*_test.rb'
      @spec_pattern   = 'spec/**/*_spec.rb'
      @local_branch   = 'master'
      @remote         = 'origin'
      @remote_branch  = 'master'
      
      
      yield(self) if block_given?

      @git = Git.open(@root_dir)      
      load_gemspec!      
      define_tasks!
    end
    
    protected
    
    def define_test_tasks!
      require 'rake/testtask'

      namespace(:test) do
        Rake::TestTask.new(:basic) do |t|
          t.pattern = test_pattern
          t.verbose = true
          t.libs << 'test'
        end
      end
      
      desc "Run all unit tests for #{gemspec.name}"
      task(:test => ['test:basic'])
    end
    
    def define_rspec_tasks!
      require 'spec/rake/spectask'

      namespace(:spec) do
        desc "Verify all RSpec examples for #{gemspec.name}"
        Spec::Rake::SpecTask.new(:basic) do |t|
          t.spec_files = FileList[spec_pattern]
        end
        
        desc "Verify all RSpec examples for #{gemspec.name} and output specdoc"
        Spec::Rake::SpecTask.new(:specdoc) do |t|
          t.spec_files = FileList[spec_pattern]
          t.spec_opts << '--format' << 'specdoc' << '--color'
        end
        
        desc "Run RCov on specs for #{gemspec.name}"
        Spec::Rake::SpecTask.new(:rcov) do |t|
          t.spec_files = FileList[spec_pattern]
          t.rcov = true
          t.rcov_opts = ['--exclude', '"spec/*,gems/*"', '--rails']          
        end          
      end
      
      desc "Verify all RSpec examples for #{gemspec.name} and output specdoc"
      task(:spec => ['spec:specdoc'])      
    end
    
    # Defines the rake tasks
    def define_tasks!
      
      define_test_tasks!  if has_tests?
      define_rspec_tasks! if has_specs?
      
      namespace(@task_namespace) do
        desc "Updates the filelist in the gemspec file"
        task(:manifest) { manifest_task } 
        
        desc "Builds the .gem package"
        task(:build => :manifest) { build_task }

        desc "Sets the version of the gem in the gemspec"
        task(:set_version => [:check_version, :check_current_branch]) { version_task }
        task(:check_version => :fetch_origin) { check_version_task }      
        
        task(:fetch_origin) { fetch_origin_task }
        task(:check_current_branch) { check_current_branch_task }        
        task(:check_clean_status) { check_clean_status_task }
        task(:check_not_diverged => :fetch_origin) { check_not_diverged_task }
        
        checks = [:check_current_branch, :check_clean_status, :check_not_diverged, :check_version]
        checks.unshift('spec:basic') if has_specs?
        checks.unshift('test:basic') if has_tests?
        checks.push << [:check_rubyforge] if gemspec.rubyforge_project
                
        desc "Perform all checks that would occur before a release"
        task(:release_checks => checks) 

        release_tasks = [:release_checks, :set_version, :build, :github_release]
        release_tasks << [:rubyforge_release] if gemspec.rubyforge_project
        
        desc "Release a new verison of the gem"
        task(:release => release_tasks) { release_task }
        
        task(:check_rubyforge)   { check_rubyforge_task }
        task(:rubyforge_release) { rubyforge_release_task }
        task(:github_release => [:commit_modified_files, :tag_version]) { github_release_task }
        task(:tag_version) { tag_version_task }
        task(:commit_modified_files) { commit_modified_files_task }
      end
    end
    
    def manifest_task
      # Load all the gem's files using "git ls-files"
      repository_files = git.ls_files.keys
      test_files       = Dir[test_pattern] + Dir[spec_pattern]
      
      update_gemspec(:files, repository_files)
      update_gemspec(:test_files, repository_files & test_files)
    end
    
    def build_task
      sh "gem build -q #{gemspec_file}"
      Dir.mkdir('pkg') unless File.exist?('pkg')
      sh "mv #{gemspec.name}-#{gemspec.version}.gem pkg/#{gemspec.name}-#{gemspec.version}.gem" 
    end
    
    def version_task
      update_gemspec(:version, ENV['VERSION']) if ENV['VERSION']
      update_gemspec(:date, Date.today)
      
      update_version_file(gemspec.version)
      update_version_constant(gemspec.version)
    end
    
    def check_version_task
      raise "#{ENV['VERSION']} is not a valid version number!" if ENV['VERSION'] && !Gem::Version.correct?(ENV['VERSION'])
      proposed_version = Gem::Version.new(ENV['VERSION'] || gemspec.version)
      # Loads the latest version number using the created tags
      newest_version   = git.tags.map { |tag| tag.name.split('-').last }.compact.map { |v| Gem::Version.new(v) }.max      
      raise "This version (#{proposed_version}) is not higher than the highest tagged version (#{newest_version})" if newest_version && newest_version >= proposed_version
    end
    
    def check_not_diverged_task
      raise "The current branch is diverged from the remote branch!" if git.log.between('HEAD', git.branches["#{remote}/#{remote_branch}"].gcommit).any?
    end
    
    def check_clean_status_task
      #raise "The current working copy contains modifications" if git.status.changed.any?
    end
    
    def check_current_branch_task
      raise "Currently not on #{local_branch} branch!" unless git.branch.name == local_branch.to_s
    end
    
    def fetch_origin_task
      git.fetch('origin')
    end
    
    def commit_modified_files_task
      if modified_files.any?
        modified_files.each { |file| git.add(file) }
        git.commit("Released #{gemspec.name} gem version #{gemspec.version}")
      end
    end
    
    def tag_version_task
      git.add_tag("#{gemspec.name}-#{gemspec.version}")
    end
    
    def github_release_task
      git.push(remote, remote_branch, true)
    end
    
    def check_rubyforge_task
      raise "Could not login on rubyforge!" unless `rubyforge login 2>&1`.strip.empty?
      output = `rubyforge names`.split("\n")
      raise "Rubyforge group not found!"   unless output.any? { |line| %r[^groups\s*\:.*\b#{Regexp.quote(gemspec.rubyforge_project)}\b.*] =~ line }
      raise "Rubyforge package not found!" unless output.any? { |line| %r[^packages\s*\:.*\b#{Regexp.quote(gemspec.name)}\b.*] =~ line }      
    end
    
    def rubyforge_release_task
      sh 'rubyforge', 'add_release', gemspec.rubyforge_project, gemspec.name, gemspec.version.to_s, "pkg/#{gemspec.name}-#{gemspec.version}.gem"
    end
    
    def release_task
      puts
      puts '------------------------------------------------------------'
      puts "Released #{gemspec.name} version #{gemspec.version}"
    end
    
    private
    
    def has_specs?
      FileList[spec_pattern].any?
    end
    
    def has_tests?
      FileList[test_pattern].any?
    end
    
    
    # Loads the gemspec file
    def load_gemspec!
      @gemspec = eval(File.read(@gemspec_file))
    end
    
    # Updates the VERSION file with the new version
    def update_version_file(version)
      if File.exists?('VERSION')
        File.open('VERSION', 'w') { |f| f << version.to_s } 
        modified_files << 'VERSION'
      end
    end
    
    # Updates the VERSION constant in the main include file if it exists
    def update_version_constant(version)
     file_contents = File.read(main_include)
     if file_contents.sub!(/^(\s+VERSION\s*=\s*)[^\s].*$/) { $1 + version.to_s.inspect }
       File.open(main_include, 'w') { |f| f << file_contents }      
       modified_files << main_include
     end
    end
    
    # Updates an attribute of the gemspec file.
    # This function will open the file, and search/replace the attribute using a regular expression.
    def update_gemspec(attribute, new_value, literal = false)
      
      unless literal
        new_value = case new_value
          when Array        then "%w(#{new_value.join(' ')})"
          when Hash, String then new_value.inspect
          when Date         then new_value.strftime('%Y-%m-%d').inspect 
          else              raise "Cannot write value #{new_value.inspect} to gemspec file!"
        end
      end
      
      spec   = File.read(gemspec_file)
      regexp = Regexp.new('^(\s+\w+\.' + Regexp.quote(attribute.to_s) + '\s*=\s*)[^\s].*$')
      if spec.sub!(regexp) { $1 + new_value }
        File.open(gemspec_file, 'w') { |f| f << spec }      
        modified_files << gemspec_file
            
        # Reload the gemspec so the changes are incorporated
        load_gemspec!
      end
    end
    
  end
end
