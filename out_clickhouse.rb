require "fluent/plugin/output"

module Fluent::Plugin
  class SQLOutput < Output
    Fluent::Plugin.register_output("sql", self)

    DEFAULT_BUFFER_TYPE = "memory"

    helpers :inject, :compat_parameters, :event_emitter

    desc "RDBMS host"
    config_param :host, :string
    desc "RDBMS port"
    config_param :port, :integer, default: nil
    desc "RDBMS driver name."
    config_param :adapter, :string
    desc "RDBMS login user name"
    config_param :username, :string, default: nil
    desc "RDBMS login password"
    config_param :password, :string, default: nil, secret: true
    desc "RDBMS database name"
    config_param :database, :string
    desc "PostgreSQL schema search path"
    config_param :schema_search_path, :string, default: nil
    desc "remove the given prefix from the events"
    config_param :remove_tag_prefix, :string, default: nil
    desc "enable fallback"
    config_param :enable_fallback, :bool, default: true
    desc "synchronizes thread access to a limited number of database connections"
    config_param :pool, :integer, default: 10
    desc "synchronizes thread access to a limited number of database connections"
    config_param :timeout, :integer, default: 5000

    config_section :buffer do
      config_set_default :@type, DEFAULT_BUFFER_TYPE
    end

    attr_accessor :tables

    # TODO: Merge SQLInput's TableElement
    class TableElement
      include Fluent::Configurable

      config_param :table, :string
      config_param :insertmapping, :string
      config_param :primary_key, :string
      config_param :num_retries, :integer, default: 5

      attr_reader :model
      attr_reader :pattern

      def initialize(pattern, log, enable_fallback)
        super()
        @pattern = Fluent::MatchPattern.create(pattern)
        @log = log
        @enable_fallback = enable_fallback
      end

      def configure(conf)
        super
        @mapping = parse_column_mapping(@insertmapping)
      end

      def init(base_model)

        #zamani: check and create table if not exist
        if !(ActiveRecord::Base.connection.table_exists? @table)
          sqlstr = "CREATE TABLE " + table + " (IDT datetime) ENGINE = MergeTree() PARTITION BY (toYYYYMM(IDT)) ORDER BY IDT"
          ActiveRecord::Base.connection.execute(sqlstr)
          @log.info "new table created :" + table

          buffersqlstr = "CREATE TABLE " + "buffer_" + table + " (IDT datetime) ENGINE = Buffer(" + table + ", winlog_fb, 16, 10, 100, 10000, 1000000, 10000000, 100000000)"
          ActiveRecord::Base.connection.execute(buffersqlstr)
          @log.info "new buffer table created : buffer_" + table
        end

        # See SQLInput for more details of following code
        table_name = @table
        @model = Class.new(base_model) do
          self.table_name = table_name
          self.primary_key = @primary_key
          self.inheritance_column = "_never_use_output_"
        end

        class_name = table_name.singularize.camelize
        base_model.const_set(class_name, @model)
        model_name = ActiveModel::Name.new(@model, nil, class_name)
        @model.define_singleton_method(:model_name) { model_name }
      end

      def import(chunk)
        records = []
        chunk.msgpack_each { |tag, time, data|
          begin
            @origdata = data
            records << @model.new(data)
          rescue #mising col in model
            #zamani: change the model and db and match it to data
            #zamani: get column of clickhouse table
            dbfiled = []
            ActiveRecord::Base.connection.columns(table).each do |c|
              dbfiled << c.name
            end
            #zamani: find all col that not exist on db
            #zamani: fluentd insert cols + log cols - current db col
            missingfileddb = @mapping.keys + @origdata.keys - dbfiled

            #zamani: add missing col to db
            sqlstr = ""
            missingfileddb.each { |x|
              sqlstr = "ALTER TABLE " + table + " ADD COLUMN IF NOT EXISTS "
              replacements = {
                "(" => "_", ")" => "_",
                "<" => "_", ">" => "_",
              }
              x.gsub(Regexp.union(replacements.keys), replacements)
              sqlstr = sqlstr + x + " Nullable(String)"
              @model.connection.execute(sqlstr) #model and db update
              @log.info "Add new col to db : " + x

              # buffer table update
              sqlstr = "ALTER TABLE " + "buffer_" + table + " ADD COLUMN IF NOT EXISTS " + x + " Nullable(String)"
              ActiveRecord::Base.connection.execute(sqlstr)
            }
            if !sqlstr.eql?("")
              @model.reset_column_information
            end

            # Import data to model
            records << @model.new(data)
          end
        }
        @log.debug "Convert chunk to model complete."
        begin
          #zamani: change the db and match it to data
          #zamani: get column of clickhouse table
          dbfiled = []
          ActiveRecord::Base.connection.columns(table).each do |c|
            dbfiled << c.name
          end
          #zamani: fluentd insert cols + log cols - current db col
          missingfiled = @mapping.keys + @origdata.keys - dbfiled
          #zamani: add missing col to db
          sqlstr = ""
          missingfiled.each { |x|
            sqlstr = "ALTER TABLE " + table + " ADD COLUMN IF NOT EXISTS "
            replacements = {
              "(" => "_", ")" => "_",
              "<" => "_", ">" => "_",
            }
            x.gsub(Regexp.union(replacements.keys), replacements)
            sqlstr = sqlstr + x + " Nullable(String)"
            @model.connection.execute(sqlstr)
            @log.info "Add new col to db : " + x

            # buffer table update
            sqlstr = "ALTER TABLE " + "buffer_" + table + " ADD COLUMN IF NOT EXISTS " + x + " Nullable(String)"
            ActiveRecord::Base.connection.execute(sqlstr)
          }
          @model.import(records)
          @log.debug "model save to db complete."
        rescue ActiveRecord::StatementInvalid, ActiveRecord::Import::MissingColumnError => e #missing col in db
          if @enable_fallback
            # ignore other exceptions to use Fluentd retry mechanizm
            @log.warn "Got deterministic error. Fallback to one-by-one import", error: e
            one_by_one_import(records)
          else
            $log.warn "Got deterministic error. Fallback is disabled", error: e
            raise e
          end
        end
      end

      def one_by_one_import(records)
        records.each { |record|
          retries = 0
          begin
            @model.import([record])
          rescue ActiveRecord::StatementInvalid, ActiveRecord::Import::MissingColumnError => e
            @log.error "Got deterministic error again. Dump a record", error: e, record: record
          rescue => e
            retries += 1
            if retries > @num_retries
              @log.error "Can't recover undeterministic error. Dump a record", error: e, record: record
              next
            end
            @log.warn "Failed to import a record: retry number = #{retries}", error: e
            sleep 0.5
            retry
          end
        }
      end

      private

      def parse_column_mapping(column_mapping_conf)
        mapping = {}
        column_mapping_conf.split(",").each { |column_map|
          key, column = column_map.strip.split(":", 2)
          column = key if column.nil?
          mapping[key] = column
        }
        mapping
      end
    end

    #-----------------------------------------------
    def initialize
      super
      require "active_record"
      require "activerecord-import"
    end

    def configure(conf)
      compat_parameters_convert(conf, :inject, :buffer)

      super

      if remove_tag_prefix = conf["remove_tag_prefix"]
        @remove_tag_prefix = Regexp.new("^" + Regexp.escape(remove_tag_prefix))
      end

      @tables = []
      @default_table = nil
      conf.elements.select { |e|
        e.name == "table"
      }.each { |e|
        te = TableElement.new(e.arg, log, @enable_fallback)
        te.configure(e)
        if e.arg.empty?
          $log.warn "Detect duplicate default table definition" if @default_table
          @default_table = te
        else
          @tables << te
        end
      }
      @only_default = @tables.empty?

      if @default_table.nil?
        raise Fluent::ConfigError, "There is no default table. <table> is required in sql output"
      end
    end

    def start
      super
      config = {
        adapter: @adapter,
        host: @host,
        port: @port,
        database: @database,
        username: @username,
        password: @password,
        schema_search_path: @schema_search_path,
        pool: @pool,
        timeout: @timeout,
      }

      @base_model = Class.new(ActiveRecord::Base) do
        self.abstract_class = true
      end
      SQLOutput.const_set("BaseModel_#{rand(1 << 31)}", @base_model)

      ActiveRecord::Base.establish_connection(config)

      # ignore tables if TableElement#init failed

      @tables.reject! do |te|
        init_table(te, @base_model)
      end
      init_table(@default_table, @base_model)
    end

    def shutdown
      super
    end

    def emit(tag, es, chain)
      if @only_default
        super(tag, es, chain)
      else
        super(tag, es, chain, format_tag(tag))
      end
    end

    def format(tag, time, record)
      # merge array to string
      record.each { |k, v|
        if (v.class == Array)
          record[k] = v.join(",")

          #cleaning data for bad UTF char
          record[k] = record[k].force_encoding("ISO-8859-1").encode("UTF-8")
        end
      }
      record = inject_values_to_record(tag, time, record)
      [tag, time, record].to_msgpack
    end

    def formatted_to_msgpack_binary
      true
    end

    def write(chunk)
      ActiveRecord::Base.connection_pool.with_connection do
        @tables.each { |table|
          if table.pattern.match(chunk.key)
            return table.import(chunk)
          end
        }
        @default_table.import(chunk)
      end
    end

    private

    def init_table(te, base_model)
      begin
        te.init(base_model)
        log.info "Selecting '#{te.table}' table"
        false
      rescue => e
        log.warn "Can't handle '#{te.table}' table. Ignoring.", error: e
        log.warn_backtrace e.backtrace
        true
      end
    end

    def format_tag(tag)
      if @remove_tag_prefix
        tag.gsub(@remove_tag_prefix, "")
      else
        tag
      end
    end
  end
end
