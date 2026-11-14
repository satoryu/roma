module Roma
  # Loads the Marshal data that clients can store, as the values of the alist,
  # map and mapcount plugins, only when it has nothing but nil, true, false,
  # numbers, Strings, Symbols, Arrays and Hashes. Marshal.load of other data
  # can make objects of any class, and links to an Array or a Hash make a
  # value that grows exponentially when it is walked.
  module SafeMarshal
    class Error < StandardError; end

    # How deep Arrays and Hashes may nest. An alist is an Array of two Arrays.
    MAX_DEPTH = 3

    # Raises Error if +data+ has anything else.
    def self.load(data)
      Checker.new(data).check
      Marshal.load(data) # rubocop:disable Security/MarshalLoad -- checked above
    end

    # Reads the Marshal format, version 4.8, without making any object.
    class Checker
      # The bytes that start each type that is allowed.
      NIL_TYPE, TRUE_TYPE, FALSE_TYPE, FIXNUM, BIGNUM, FLOAT, STRING, SYMBOL, SYMLINK, LINK, IVAR, ARRAY, HASH =
        '0TFilf":;@I[{'.bytes

      def initialize(data)
        @data = data
        @size = data.bytesize
        @pos = 0
        # Whether each object that '@' can link to is a container, in order.
        @containers = []
        @symbols = 0
      end

      def check
        raise Error, 'not Marshal data of version 4.8' unless @data.getbyte(0) == 4 && @data.getbyte(1) == 8

        @pos = 2
        value(0)
      end

      private

      def value(depth)
        case (type = byte)
        when STRING, FLOAT
          @containers << false
          skip(long)
        when FIXNUM then long
        when ARRAY
          container(depth)
          long.times { value(depth + 1) }
        when IVAR then ivars(depth)
        when NIL_TYPE, TRUE_TYPE, FALSE_TYPE then nil
        when BIGNUM
          @containers << false
          byte
          skip(long * 2)
        when SYMBOL, SYMLINK then symbol(type)
        when LINK then raise Error, 'link to a container' unless @containers[long] == false
        when HASH
          container(depth)
          long.times do
            value(depth + 1)
            value(depth + 1)
          end
        else raise Error, "type #{type.chr.inspect} is not allowed"
        end
      end

      # A String with its encoding, or another object with instance
      # variables.
      def ivars(depth)
        value(depth)
        long.times do
          symbol(byte)
          value(depth)
        end
      end

      def symbol(type)
        if type == SYMBOL
          @symbols += 1
          skip(long)
        elsif type == SYMLINK
          raise Error, 'bad symbol link' unless long < @symbols
        else
          raise Error, 'an instance variable without a Symbol'
        end
      end

      def container(depth)
        raise Error, 'nested too deep' if depth >= MAX_DEPTH

        @containers << true
      end

      def byte
        b = @data.getbyte(@pos) or raise Error, 'too short'
        @pos += 1
        b
      end

      def skip(length)
        @pos += length
        raise Error, 'too short' if length.negative? || @pos > @size
      end

      # The packed integer of the Marshal format.
      def long
        c = byte
        return c - 5 if c > 4 && c < 128

        c -= 256 if c > 127
        return 0 if c.zero?
        return c + 5 if c < -4

        x = 0
        c.abs.times { |i| x |= byte << (8 * i) }
        c.negative? ? x - (256**c.abs) : x
      end
    end
  end
end
