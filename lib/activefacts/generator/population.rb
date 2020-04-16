#
#       ActiveFacts Population Generator
#
# Copyright (c) 2018 Clifford Heath. Read the LICENSE file.
#
require 'digest/sha1'
require 'activefacts/metamodel'
require 'activefacts/metamodel/datatypes'
require 'activefacts/compositions'
require 'activefacts/compositions/names'
require 'activefacts/generator'
require 'activefacts/generator/traits/sql'

module ActiveFacts
  module Generators
    class Population

      MM = ActiveFacts::Metamodel unless const_defined?(:MM)
      def self.options
        # REVISIT: There's no way to support SQL dialect options here
        sql_trait = ActiveFacts::Generators::Traits::SQL
        Class.new.extend(sql_trait).  # Anonymous class to enable access to traits module instance methods
        options.
        merge(
          {
            dialect: [String, "SQL Dialect to use"],
            population: [String, "Name of the fact population to process (defaults to anonymous seed population)"],
          }
        )
      end

      def self.compatibility
        [1, %i{relational}]   # one relational composition
      end

      def initialize constellation, composition, options = {}
        @constellation = constellation
        @composition = composition
        @options = options

        @trait = ActiveFacts::Generators::Traits::SQL
        if @dialect = options.delete("dialect")
          require 'activefacts/generator/traits/sql/'+@dialect
          trait_name = ActiveFacts::Generators::Traits::SQL.constants.detect{|c| c.to_s =~ %r{#{@dialect}}i}
          @trait = @trait.const_get(trait_name)
        end
        self.class.include @trait
        self.class.extend @trait
        extend @trait
        @population_name = options.delete("population") || ''

        process_options options
      end

      def process_options options
        super
      end

      def generate
        @constellation = @composition.constellation
        @vocabulary = @constellation.Vocabulary.values[0]
        @population = @constellation.Population[[[@vocabulary.name], @population_name]]
        raise "Population #{@population_name.inspect} doesn't exist in #{@vocabulary.name.inspect}" unless @population_name
        @composites = @composition.all_composite.select{|c| c.mapping.object_type.all_instance.size > 0}
        header +
          @composites.
          map{|c| generate_composite c}.
          compact*"\n\n" +
        trailer
      end

      def header
        schema_prefix
      end

      def generate_composite composite
        leaf_column_names = composite.mapping.all_leaf.map do |leaf|
          [leaf, safe_column_name(leaf)]
        end

        "-- #{composite.mapping.name}\n" +
        composite.mapping.object_type.all_instance.map do |instance|
          ncv = named_column_values leaf_column_names, instance
          %Q{INSERT INTO #{safe_table_name composite}(#{ncv.map{|name, value|name}*', '})\n} +
          %Q{\tVALUES (#{ncv.map{|name, value| value}*', '});}
        end.sort * "\n"
      end

      def named_column_values leaf_column_names, instance
        leaf_column_names.map do |leaf, column_name|
          current = instance
          value = nil
          leaf.path[1..-1].each do |component|
            trace :population, "Traversing #{component.inspect}" do
              case component
              when MM::Absorption       # Fact
                fact_type = component.parent_role.fact_type
                trace :population, "Fact Type #{fact_type.default_reading}"

                if MM::LinkFactType === fact_type
                  # Populations do not contain LinkFactTypes for an Objectified Fact Type,
                  # but Compositions use them. The child_role is probably a mirror role.
                  role = fact_type.implying_role  # This is the real role
                  fact_type = role.fact_type      # And this is the real fact
                  raise "Internal error finding objectified fact" if instance.fact.fact_type != fact_type
                  role_value = fact.all_role_value{|rv| rv.role == role}
                else
                  role_values = instance.all_role_value.select{|rv| rv.population == @population && rv.fact.fact_type == fact_type}
                  raise "Population contains duplicate fact for #{fact_type.default_reading.inspect} in violation of uniqueness constraint" if role_values.size > 1
                  if role_values.empty?
                    trace :population, "No fact is present"
                    break
                  end
                  residual_rvs = role_values[0].fact.all_role_value.to_a-[role_values[0]]
                  raise "Instance of #{fact_type.default_reading.inspect} lacks some role players" unless residual_rvs.size == fact_type.all_role.size-1
                  if residual_rvs.size != 1
                    raise "Internal error in fact population, n-ary fact type #{fact_type.default_reading}"
                  end
                  role_value = residual_rvs[0]
                end

                current = role_value.instance
                trace :population, "Instance is #{current.object_type.name}#{current.value ? ' = '+current.value.inspect : ''}"
                value = current.value.inspect

              when MM::Indicator
                fact_type = component.role.fact_type
                trace :population, "Fact Type #{fact_type.default_reading}"
                role_values = instance.all_role_value.select{|rv| rv.population == @population && rv.fact.fact_type == fact_type}
                raise "Population contains duplicate fact for #{fact_type.default_reading.inspect} in violation of uniqueness constraint" if role_values.size > 1
                value = true

              when MM::ValueField
                # The value is the value of the Value Type
                value = current.value.inspect

              when MM::Discriminator
                # The value depends on which of the discriminated roles are played (must be only one)
                raise "Cannot emit population containing a Discriminator, not implemented"
                drs = component.all_discriminated_role.select{|dr| instance.all_role_value.detect{|rv| rv.role == dr.role}}
                raise "Discriminator has ambiguous value, with more than one candidate role" if drs.size > 1
                value = drs[0].value.inspect if drs[0]

              # The following types are not conceptual so will never have asserted facts
              when MM::Injection,
                   MM::Scoping,
                   MM::SurrogateKey,
                   MM::ValidFrom,
                   MM::Mapping,
                   MM::ComputedValue,
                   MM::HashValue
                break

              else
                raise "Unhandled Component type #{component.class.name} in composition"
              end
            end
          end
          value ? [column_name, value] : nil
        end.compact
      end

      def trailer
        ''
      end

      def stylise_column_name name
        name.words.send(@column_case)*@column_joiner
      end

    end
    publish_generator Population, "Generate SQL to insert or update records defined as a fact population"
  end
end
