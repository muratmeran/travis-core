require 'active_support/concern'
require 'active_support/core_ext/hash/keys'
require 'core_ext/array/flatten_once'
require 'core_ext/hash/deep_symbolize_keys'

class Build
  module Matrix
    extend ActiveSupport::Concern

    ENV_KEYS = [:rvm, :gemfile, :env, :otp_release, :php, :node_js]

    module ClassMethods
      def matrix?(config)
        config.values_at(*ENV_KEYS).compact.any? { |value| value.is_a?(Array) && value.size > 1 }
      end

      def matrix_keys_for(config)
        keys = ENV_KEYS + [:branch]
        keys & config.keys.map(&:to_sym)
      end
    end

    # Return only the child builds whose config matches against as passed hash
    # e.g. build.matrix_for(rvm: '1.8.7', env: 'DB=postgresql')
    def matrix_for(config)
      config.blank? ? matrix : matrix.select { |job| job.matrix_config?(config) }
    end

    def matrix_finished?(*)
      matrix.all?(&:finished?)
    end

    def matrix_status(config = {})
      tests = matrix_for(config)
      if tests.blank?
        nil
      elsif tests.all?(&:passed?)
        0
      elsif tests.any?(&:failed?)
        1
      else
        nil
      end
    end

    protected

      def expand_matrix
        expand_matrix_config(matrix_config.to_a).each_with_index do |row, ix|
          attributes = self.attributes.slice(*Job.column_names).symbolize_keys
          attributes.merge!(:number => "#{number}.#{ix + 1}", :config => config.merge(Hash[*row.flatten]), :log => Artifact::Log.new)
          matrix.build(attributes)
        end
      end

      def matrix_config
        @matrix_config ||= begin
          config = self.config || {}
          keys   = ENV_KEYS & config.keys.map(&:to_sym)
          size   = config.slice(*keys).values.select { |value| value.is_a?(Array) }.max { |lft, rgt| lft.size <=> rgt.size }.try(:size) || 1

          keys.inject([]) do |result, key|
            values = config[key]
            values = [values] unless values.is_a?(Array)
            values += [values.last] * (size - values.size) if values.size < size
            result << values.map { |value| [key, value] }
          end
        end
      end

      def expand_matrix_config(config)
        # recursively builds up permutations of values in the rows of a nested array
        matrix = lambda do |*args|
          base, result = args.shift, args.shift || []
          base = base.dup
          base.empty? ? [result] : base.shift.map { |value| matrix.call(base, result + [value]) }.flatten_once
        end
        expanded = matrix.call(config).uniq
        exclude_matrix_configs(expanded)
      end

      def exclude_matrix_configs(matrix)
        matrix.reject { |config| exclude_config?(config) }
      end

      def exclude_config?(config)
        # gotta make the first key a string for 1.8 :/
        exclude_configs = config_matrix_settings[:exclude] || []
        exclude_configs = exclude_configs.map(&:stringify_keys).map(&:to_a).map(&:sort)
        config = config.map { |config| [config[0].to_s, *config[1..-1]] }.sort
        exclude_configs.to_a.any? { |excluded| excluded == config }
      end

      def config_matrix_settings
        config = self.config || {}
        config[:matrix] || {}
      end
  end
end
