require 'test_helper'
require 'stringio'
require 'tool_test_helper'
require 'roma/tools/roma_watcher'

class RomaWatcherTest < Test::Unit::TestCase
  include ToolTestHelper

  # Keeps the mails instead of sending them.
  class FakeMailer
    attr_reader :mails

    def initialize
      @mails = []
    end

    def send_mail(subject, body)
      @mails << [subject, body]
    end
  end

  def setup
    super
    @mailer = FakeMailer.new
    @log = StringIO.new
  end

  def config(nodes, count: 2)
    { 'roma' => nodes, 'timeout' => 0.5, 'retry' => { 'count' => count, 'period' => 0 },
      'mail' => { 'subject_prefix' => 'ROMA ' }, 'log' => {} }
  end

  def watch(nodes, **opts)
    Roma::Tools::RomaWatcher.new(config(nodes, **opts), logger: Logger.new(@log), mailer: @mailer).watch
  end

  def answering(nodelist)
    fake_node.tap { |node| node.replies['nodelist'] = "#{nodelist}\r\n" }
  end

  def addr(node)
    node.nid.sub('_', ':')
  end

  def test_all_right
    nodes = [answering('a b'), answering('a b')]
    assert_equal [], watch(nodes.map { |n| addr(n) })
    assert_empty @mailer.mails
    assert_equal ['nodelist'], nodes[0].commands
  end

  def test_split_brain
    nodes = [answering('a b'), answering('a b'), answering('c')]
    assert_equal ['ROMA Split brain'], watch(nodes.map { |n| addr(n) })
    assert_equal [['ROMA Split brain', "a,b\r\nc\r\n"]], @mailer.mails
  end

  # Tried as many times as the retry count.
  def test_node_down
    node = answering('a')
    down = down_node.sub('_', ':')
    assert_equal ['ROMA A node down'], watch([addr(node), down], count: 3)
    subject, body = @mailer.mails[0]
    assert_equal 'ROMA A node down', subject
    assert_match(/\ACatch an error when checking a node: #{down}: /, body)
    assert_equal 2, @log.string.scan(/retry: \d times/).size
  end

  # Not split, when the nodes that answer know the same nodes.
  def test_all_down
    assert_equal ['ROMA A node down'] * 2, watch([down_node, down_node], count: 1)
  end

  # Answers after it failed once.
  def test_retry
    node = fake_node
    tries = 0
    node.replies['nodelist'] = proc { (tries += 1) == 1 ? '' : "a\r\n" }
    assert_equal [], watch([addr(node)])
    assert_equal 2, tries
  end

  def test_mailer
    out = File.join(@dir, 'mail')
    sendmail = File.join(@dir, 'sendmail')
    File.write(sendmail, "#!/bin/sh\necho \"$@\" > #{out}.args\ncat > #{out}\n")
    File.chmod(0o755, sendmail)
    Roma::Tools::RomaWatcher::Mailer.new('from@example.com', 'to@example.com', sendmail).send_mail('subject', 'body')
    assert_equal "-f from@example.com -t\n", File.read("#{out}.args")
    assert_equal "From: from@example.com\nTo: to@example.com\nSubject: subject\nReply-To: from@example.com\n\nbody\n",
                 File.read(out)
  end

  def test_mailer_failed
    sendmail = File.join(@dir, 'sendmail')
    File.write(sendmail, "#!/bin/sh\ncat > /dev/null\nexit 1\n")
    File.chmod(0o755, sendmail)
    mailer = Roma::Tools::RomaWatcher::Mailer.new('from@example.com', 'to@example.com', sendmail)
    assert_raise_message(/\A#{sendmail} failed: .*exit 1/) { mailer.send_mail('subject', 'body') }
  end
end
