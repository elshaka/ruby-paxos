# frozen_string_literal: true

require 'securerandom'
require 'timeout'

class Node
  HEARTBEAT_INTERVAL = 0.5
  HEARTBEAT_TIMEOUT = HEARTBEAT_INTERVAL + 0.2
  HEARTBEAT_TIMEOUT_RAND_MULTIPLIER = 10
  MAX_HEARTBEAT_TIMEOUT = HEARTBEAT_TIMEOUT + HEARTBEAT_TIMEOUT_RAND_MULTIPLIER

  attr_reader :uuid, :name, :log, :inbox_log, :role

  def initialize(name)
    @name = name
    @uuid = SecureRandom.uuid
    @role = :follower
    @status = :alive
    @neighbors = Set.new
    @leader = nil
    @inbox = Queue.new
    @inbox_log = []
    @log = []
    @votes = Set.new
  end

  def add_neighbor(node)
    @neighbors << node
  end

  def propose_state(state)
    send(self, :propose_state, state)
  end

  def simulate_failure
    fail
  end

  def remove_neighbor(node)
    @neighbors.delete(node)
  end

  def start
    puts "Node #{name} has started"
    @inbox_thread = Thread.new do
      loop do
        break if stopped? || failed?

        sender, type, content = begin
          receive
        rescue StandardError
          break
        end

        @inbox_log << { sender: sender.name, type: type, content: content } unless %i[timeout heartbeat].include? type

        case type
        when :heartbeat
          if sender != @leader
            if @leader
              warn "#{name} received a hearbeat from #{sender.name} but its leader is #{@leader.name}"
            else
              warn "#{name} received a hearbeat from #{sender.name} but has no leader"
            end
          end
        when :propose_state
          if leader?
            puts "#{name} (leader) received a state proposal (#{content})"
            log_state content
            propagate_state content
          else
            puts "#{name} received a state proposal (#{content}) but it's not the leader, fowarding proposal"
            propose_state_to_leader content
          end
        when :log_state
          log_state content
        when :leader_election_request
          vote_for_a_leader sender
        when :leader_election_vote
          handle_vote sender, content
        when :set_leader
          become_follower sender
        when :timeout
          unless leader?
            puts "#{name} received no leader heartbeat, requesting a leader election"
            request_leader_election
          end
        else
          puts "#{name} received #{{ sender: sender.name, type: type, content: content }} (unkown message type)"
        end

        break if stopped? || failed?
      end
    end

    @heartbeat_thread = Thread.new do
      loop do
        break if stopped? || failed?

        heartbeat if leader?
        sleep HEARTBEAT_INTERVAL
      end
    end
  end

  def stop
    @status = :stopped
    puts "#{name} has been stopped"
  end

  def propose_state_to_leader(state)
    unless @leader
      warn "Node #{name} does not have a leader to foward a state proposal, the new state proposal has been lost"
      return
    end

    @leader.send(self, :propose_state, state)
  end

  def propagate_state(state)
    # raise "Node #{self} it's not the leader and cannot propagate the state #{state}" unless leader?

    @neighbors.each do |node|
      node.send self, :log_state, state
    end
    puts "State '#{state}' has been propagated"
  end

  def log_state(content)
    @log << content
  end

  def request_leader_election
    raise "Node #{self} is the leader and cannot request a leader election" if leader?

    @neighbors.each do |node|
      node.send self, :leader_election_request
    end
  end

  def vote_for_a_leader(election_initiator_node)
    # raise "Node #{self} is the leader and cannot vote in a leader election" if leader?

    # It currently votes for whoever initiated the election, no questions asked :'D
    # TODO: Improve voting criteria
    election_initiator_node.send self, :leader_election_vote, election_initiator_node.uuid
  end

  def handle_vote(voter, candidate)
    @votes << { voter: voter, candidate: candidate }
    return unless @votes.count == @neighbors.count

    approvals = @votes.select { |vote| vote[:candidate] == @uuid }
    become_leader if approvals.count >= @neighbors.count / 2

    @votes = Set.new
  end

  def send(sender, type, content = nil)
    @inbox << [sender, type, content]
  end

  def become_leader
    puts "#{name} is now the leader"
    @neighbors.each { |node| node.send self, :set_leader }
    @role = :leader
  end

  def become_follower(leader)
    @role = :follower
    @leader = leader
  end

  def fail
    @neighbors.each do |node|
      node.remove_neighbor self
      node.leader = nil if node.leader == self
    end
    @neighbors = Set.new
    @status = :failed
    puts "#{name} has failed"
  end

  def join
    @inbox_thread.join
    @heartbeat_thread.join
  end

  def leader?
    @role == :leader
  end

  def follower?
    @role == :follower
  end

  def stopped?
    @status == :stopped
  end

  def failed?
    @status == :failed
  end

  def receive
    Timeout.timeout(HEARTBEAT_TIMEOUT + HEARTBEAT_TIMEOUT_RAND_MULTIPLIER * rand) do
      loop do
        raise 'ded' if stopped? || failed?
        break unless @inbox.empty?
      end
      @inbox.pop
    end
  rescue Timeout::Error
    [self, :timeout, nil]
  end

  def heartbeat
    @neighbors.each do |node|
      node.send self, :heartbeat
    end
  end
end
