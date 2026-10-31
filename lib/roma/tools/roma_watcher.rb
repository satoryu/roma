require 'logger'
require 'roma/tools/admin_client'
require 'roma/tools/error'

module Roma
  module Tools
    # Asks each node for the nodes it knows, and mails if a node doesn't
    # answer, or the nodes don't know the same nodes (split brain).
    # roma_watcher_config.yml.example is an example of the config.
    class RomaWatcher
      ERROR_NODE_DOWN = 'A node down'.freeze
      ERROR_SPLIT_BRAIN = 'Split brain'.freeze

      # Sends a mail by sendmail.
      class Mailer
        def initialize(from, to, mailer = '/usr/lib/sendmail')
          @from = from
          @to = to
          @mailer = mailer
        end

        def send_mail(subject, body)
          IO.popen([@mailer, '-f', @from, '-t'], 'w') do |io|
            io.puts "From: #{@from}", "To: #{@to}", "Subject: #{subject}", "Reply-To: #{@from}", '', body
          end
          raise Error, "#{@mailer} failed: #{$?}" unless $?.success?
        end
      end

      # +config+ is the loaded YAML. The nodes are asked by +client+, and
      # the mails are sent by +mailer+.
      def initialize(config, logger: nil, mailer: nil, client: nil)
        @config = config
        @logger = logger || Logger.new(config['log']['path'], config['log']['rotate'])
        mail = config['mail']
        @mailer = mailer || Mailer.new(mail['from'], mail['to'], *mail['mailer'])
        @subject_prefix = mail['subject_prefix'].to_s
        @client = client || AdminClient.new(timeout: config['timeout'].to_f)
      end

      # Watches the nodes, and returns the subjects of the mails sent.
      def watch
        @logger.info 'start watching a ROMA'
        nodelists = {}
        errors = {}
        @config['roma'].each do |node|
          nodelists[node] = nodelist(node)
        rescue Error => e
          errors[node] = "Catch an error when checking a node: #{e.message}"
        end
        @logger.info 'end watching'
        errors.values.map { |message| mail(ERROR_NODE_DOWN, message) } +
          check_split_brain(nodelists.values.uniq)
      end

      private

      # Tries again as many times as retry count.
      def nodelist(node)
        tries = 0
        begin
          @client.request(node, 'nodelist').split
        rescue Error => e
          @logger.error "Catch an error when checking a node: #{e.message}"
          tries += 1
          raise if tries >= @config['retry']['count'].to_i
          @logger.info "retry: #{tries} times"
          sleep @config['retry']['period'].to_f
          retry
        end
      end

      def check_split_brain(nodelists)
        return [] if nodelists.size <= 1
        [mail(ERROR_SPLIT_BRAIN, nodelists.map { |nodes| "#{nodes.join(',')}\r\n" }.join)]
      end

      def mail(error, body)
        subject = @subject_prefix + error
        @logger.error "#{subject}: #{body}"
        @mailer.send_mail(subject, body)
        subject
      end
    end
  end
end
