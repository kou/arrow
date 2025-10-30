require_relative "org/apache/arrow/flatbuf/footer"
require_relative "org/apache/arrow/flatbuf/message"
require_relative "org/apache/arrow/flatbuf/schema"

module ArrowFormat
  class FileReader
    def initialize(view)
      @view = view
    end

    def read
      magic = "ARROW1"
      raise "No ARROW1 start marker" unless @view.start_with?(magic)
      raise "No ARROW1 end marker" unless @view.end_with?(magic)

      footer_size = @view.unpack1("l<", offset: @view.size - magic.size - 4) # sizeof(int32_t)
      # TODO: Use data and offset instead of @view[]
      footer_data = @view[@view.size - magic.size - 4 - footer_size, footer_size]
      footer = Org::Apache::Arrow::Flatbuf::Footer.new(footer_data)

      stream_format_offset = 8 # <empty padding bytes [to 8 byte boundary]>
      offset = stream_format_offset
      valid_continuation = "\xFF\xFF\xFF\xFF".b
      schema = nil
      # streaming format
      loop do
        continuation = @view[offset, valid_continuation.bytesize]
        raise "No valid continuation" unless continuation == valid_continuation
        offset += valid_continuation.bytesize

        metadata_size = @view.unpack1("l<", offset: offset)
        offset += 4 # sizeof(int32_t)
        break if metadata_size.zero?

        metadata_data = @view[offset, metadata_size]
        offset += metadata_size
        metadata = Org::Apache::Arrow::Flatbuf::Message.new(metadata_data)
        pp metadata

        pp [:body_length, metadata.body_length]
        body = @view[offset, metadata.body_length]
        header = metadata.header
        case header
        when Org::Apache::Arrow::Flatbuf::Schema
          schema = read_schema(header)
        when Org::Apache::Arrow::Flatbuf::RecordBatch
          n_rows = header.length
          columns = []
          buffers = header.buffers
          schema.fields.each do |field|
            columns << read_column(field, n_rows, buffers, body)
          end
          pp columns.collect(&:to_a)
          pp RecordBatch.new(schema, n_rows, columns)
        end

        offset += metadata.body_length
      end
    end

    private
    def read_schema(fb_schema)
      fields = fb_schema.fields.collect do |fb_field|
        fb_type = fb_field.type
        case fb_type
        when Org::Apache::Arrow::Flatbuf::Int
          case fb_type.bit_width
          when 8
            if fb_type.signed?
              type = Int8Type.new
            else
              type = UInt8Type.new
            end
          end
        end
        Field.new(fb_field.name, type)
      end
      Schema.new(fields)
    end

    def read_column(field, n_rows, buffers, body)
      case field.type
      when UInt8Type
        validity_buffer = buffers.shift
        if validity_buffer.length.zero?
          validity = nil
        else
          validity = body[validity_buffer.offset, validity_buffer.length]
        end

        values_buffer = buffers.shift
        values = body[values_buffer.offset, values_buffer.length]
        UInt8Array.new(n_rows, validity, values)
      end
    end
  end

  class Type
    attr_reader :name
    def initialize(name)
      @name = name
    end
  end

  class IntType < Type
    attr_reader :bit_width
    attr_reader :signed
    def initialize(name, bit_width, signed)
      super(name)
      @bit_width = bit_width
      @signed = signed
    end
  end

  class Int8Type < IntType
    def initialize
      super("Int8", 8, true)
    end
  end

  class UInt8Type < IntType
    def initialize
      super("UInt8", 8, false)
    end
  end

  class Field
    attr_reader :name
    attr_reader :type
    def initialize(name, type)
      @name = name
      @type = type
    end
  end

  class Schema
    attr_reader :fields
    def initialize(fields)
      @fields = fields
    end
  end

  class UInt8Array
    attr_reader :size
    def initialize(size, validity_raw, values_raw)
      @size = size
      @validity_raw = validity_raw
      @values_raw = values_raw
    end

    def to_a
      @values_raw.unpack("C*")
    end
  end

  class RecordBatch
    attr_reader :schema
    attr_reader :n_rows
    attr_reader :columns
    def initialize(schema, n_rows, columns)
      @schema = schema
      @n_rows = n_rows
      @columns = columns
    end

    def to_h
      hash = {}
      @schema.fields.zip(@columns) do |field, column|
        hash[field.name] = column
      end
      hash
    end
  end
end

File.open("/var/tmp/x.arrow", "rb") do |input|
  reader = ArrowFormat::FileReader.new(input.read.b)
  pp reader.read
end
