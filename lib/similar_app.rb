require 'set'

module SimilarApp
  class << self
    def blacklist(field)
      @blacklist_set ||= {}
      @blacklist_set[field.to_s] ||= begin
        blacklist_file = Rails.root.join("lib", "blacklists", "#{field.to_s.gsub(/^sig_/,'')}.blacklist")
        Set.new File.open(blacklist_file).readlines.map(&:chomp)
      end
    end

    def filter_app_signature(app, field)
      bl = blacklist(field)
      Set.new(app[field].reject { |s| bl.include? s })
    end

    def get_similar_apps(app, options={})
      field      = options[:field]     || :sig_resources_100
      threshold  = options[:threshold] || 0.8
      min_count  = options[:min_count] || 1

      return [] if app[field].try(:size).to_i < min_count

      app_signature = filter_app_signature(app, field)

      signatures_for_es = app_signature.to_a
      if signatures_for_es.size > 1024
        # maxClausecount == 1024 in ES by default, and it's sufficient
        # We'll take a 1024 entres signature sample
        signatures_for_es = signatures_for_es.shuffle[0...1024]
      end

      result = App.index("signatures").search(
        :size => 100,
        :fields => [:_id, :downloads, field],

        :query => {
          :terms => {
            field => signatures_for_es,
            :minimum_match => (signatures_for_es.size * threshold).to_i
          }
        }
      )

      # result contains app
      similar_apps = []
      result.results.each do |match|
        match_signature = filter_app_signature(match, field)
        score = (match_signature & app_signature).size.to_f / 
                (match_signature | app_signature).size.to_f

        if score >= threshold
          similar_apps << {:id => match._id, :downloads => match.downloads, :score => score}
        end
      end
      similar_apps
    end

    def merge(similar_apps, prefix)
      return if similar_apps.size < 2
      similar_apps = similar_apps.sort_by { |s| -s[:downloads] }
      apps = similar_apps.map { |s| s[:id] }
      downloads = similar_apps.map { |s| s[:downloads] }

      @@merge_scripts ||= {}
      @@merge_scripts[prefix] ||= Redis::Script.new <<-SCRIPT
        local apps = KEYS
        local downloads = ARGV

        local current_dup_id = nil
        local current_dup_downloads = 0

        -- get the highest downloaded dup among already set dup
        for i, app in ipairs(apps) do
          local res = redis.call('hmget', '#{prefix}:dup:' .. app, 'dup_id', 'dup_downloads')
          if res[1] then
            local dup_id = res[1]
            local dup_downloads = tonumber(res[2])

            if current_dup_downloads < dup_downloads then
              current_dup_id = dup_id
              current_dup_downloads = dup_downloads
            end
          end
        end

        if not current_dup_id then
          -- fresh new dup (first one has the highest downloads)
          current_dup_id = apps[1]
          current_dup_downloads = downloads[1]
        end

        local current_dup_set = '#{prefix}:root:' ..  current_dup_id

        for i, app in ipairs(apps) do
          local old_dup_id = redis.call('hget', '#{prefix}:dup:' .. app, 'dup_id')
          if app ~= current_dup_id then
            if old_dup_id then
              if old_dup_id ~= current_dup_id then
                -- merge old set with the current one
                local old_dup_set = '#{prefix}:root:' ..  old_dup_id
                local old_dup_ids = redis.call('smembers', old_dup_set)

                for j, old_app in ipairs(old_dup_ids) do
                  redis.call('hmset', '#{prefix}:dup:' .. old_app, 'dup_id', current_dup_id, 'dup_downloads', current_dup_downloads)
                end
                redis.call('sunionstore', current_dup_set, current_dup_set, old_dup_set)
                redis.call('del', old_dup_set)
              end
            else
              -- new app registered
              redis.call('hmset', '#{prefix}:dup:' .. app, 'dup_id', current_dup_id, 'dup_downloads', current_dup_downloads)
              redis.call('sadd', current_dup_set, app)
            end
          end
        end
      SCRIPT

      @@merge_scripts[prefix].eval(Redis.for_apps, :keys => apps, :argv => downloads)
    end

    def process(app_id, options={})
      app = App.find("signatures", app_id, :no_raise => true)
      if app
        cutoff = options.delete(:cutoff)
        raise "cutoff?" unless cutoff

        similar_apps_resources = get_similar_apps(app, options.merge(:field => "sig_resources_#{cutoff}"))
        similar_apps_hashes    = get_similar_apps(app, options.merge(:field => "sig_asset_hashes_#{cutoff}"))

        merge(similar_apps_resources, 'res')
        merge(similar_apps_hashes,    'hashes')
        merge(similar_apps_resources, 'all')
        merge(similar_apps_hashes,    'all')
      end
    end

    ##########################################################################3

    def get_matching_sets(prefix)
      root_apps = Redis.for_apps.keys "#{prefix}:root:*"
      sets = Redis.for_apps.pipelined do
        root_apps.map { |app| Redis.for_apps.smembers(app) }
      end
      root_apps.map! { |app| app.gsub(/^#{prefix}:root:/, '') }
      Hash[root_apps.zip(sets).sort_by { |r| -r[1].count }]
    end

    def get_queue_size
      Sidekiq::Stats.new.queues["match_similar_app"]
    end

    def get_decompiled_app_ids
      App.index("signatures").search(
        :size   => 10_000_000,
        :query  => {:match_all => {}},
        :filter => {:term => {:decompiled => true}},
        :fields => [:_id]
      ).results.map(&:_id)
    end

    def batch(options={})
      app_ids = options.delete(:app_ids)

      result_file = Rails.root.join('matches', options.values.join("_"))
      if result_file.exist?
        STDERR.puts "*** Skipping #{options} ***"
        return
      end

      app_ids ||= get_decompiled_app_ids

      raise "queue is not empty" unless get_queue_size.zero?
      Redis.for_apps.flushdb

      STDERR.puts "---> Processing #{options}"
      total = app_ids.count
      app_ids.each { |app_id| MatchSimilarApp.perform_async(app_id, options) }

      require 'ruby-progressbar'
      bar = ProgressBar.create(:format => '%t |%b>%i| %c/%C %e', :title => "Matcher", :total => total)
      loop do
        left = get_queue_size
        if left == 0
          bar.finish
          break
        end
        bar.progress = total - left
        sleep 1
      end

      result = { :resources    => get_matching_sets('res'),
                 :asset_hashes => get_matching_sets('hashes'),
                 :all          => get_matching_sets('all') }

      File.open(result_file, 'w') do |f|
        f.puts MultiJson.dump(result, :pretty => true)
      end
      true
    end

    def batch_all
      app_ids = get_decompiled_app_ids
      [100, 300, 1000, 3000].each do |cutoff|
        [0.6, 0.7, 0.8, 0.9, 1.0].reverse.each do |threshold|
          batch(:app_ids => app_ids, :threshold => threshold, :cutoff => cutoff)
        end
      end
      true
    end
  end
end
