require 'digest/sha1'

module Roma
  module Routing
    class MerkleTree
      attr_reader :tree, :divide_bits, :digest_bits

      def initialize(digest_bits, divide_bits)
        @tree = {}
        @digest_bits = digest_bits
        @divide_bits = divide_bits
        create_tree_instance('0')
      end

      def set(vnode, nodes)
        id = '0' + (vnode >> (@digest_bits - @divide_bits)).to_s(2).rjust(@divide_bits, '0')
        @tree[id] = Digest::SHA1.hexdigest(nodes.to_s)
        update(parent(id))
      end

      def get(id)
        @tree[id]
      end

      def to_vnode(id)
        id[1, id.length].to_i(2) << (@digest_bits - @divide_bits)
      end

      private

      def create_tree_instance(id)
        @tree[id] = 0
        return if id.length > @divide_bits

        create_tree_instance("#{id}0")
        create_tree_instance("#{id}1")
      end

      def update(id)
        @tree[id] = Digest::SHA1.hexdigest("#{@tree[id + '0']}:#{@tree[id + '1']}")
        update(parent(id)) if id.length != 1
      end

      def parent(id)
        id.chop
      end
    end # class MerkleTree
  end # module Routing
end # module Roma
