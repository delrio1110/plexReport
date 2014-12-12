#!/usr/bin/ruby
require 'rubygems'
require 'bundler/setup'
require 'time'
require 'date'
require 'yaml'
require 'erb'
require 'logger'
require 'optparse'

require_relative 'plex'
require_relative 'themoviedb'
require_relative 'thetvdb'
require_relative 'omdb'
require_relative 'mailReport'

# Class for parsing the Plex server for new movies and TV Shows
#
# Author: Brian Stascavage
# Email: brian@stascavage.com
#
class PlexReport
    $options = {
        :emails        => true,
        :library_names => false,
        :test_email    => false,
        :detail_email  => false,
        :full	       => false,
        :debug         => false
    }

    OptionParser.new do |opts|
        opts.banner = "PlexReport: A script for sending out regular Plex summaries\nUsage: plexReport.rb [$options]"

        opts.on("-a", "--all-media", "Scans full library.  Takes a long time; only for servers that have large updates") do |opt|
            $options[:full] = true
        end

        opts.on("-d", "--detailed-email", "Send more details in the email, such as movie ratings, actors, etc") do |opt|
            $options[:detail_email] = true
        end

        opts.on("-l", "--add-library-names", "Adding the Library name in front of the movie/tv show.  To be used with custom Libraries") do |opt|
            $options[:library_names] = true
        end

        opts.on("-n", "--no-plex-email", "Do not send emails to Plex friends") do |opt|
            $options[:emails] = false
        end

    	opts.on("-t", "--test-email", "Send email only to the Plex owner (ie yourself).  For testing purposes") do |opt|
	        $options[:test_email] = true
	    end

        opts.on("-v", "--verbose", "Enable verbose debug logging") do |opt|
            $options[:verbose] = true
        end
    end.parse!

    def initialize
        begin
            $config = YAML.load_file(File.join(File.expand_path(File.dirname(__FILE__)), '../etc/config.yaml') )
        rescue Errno::ENOENT => e
            abort('Configuration file not found.  Exiting...')
        end

        begin
            $logging_path = File.join(File.expand_path(File.dirname(__FILE__)), '../plexReport.log') 
            $logger = Logger.new($logging_path)
            
            if $options[:verbose]
                $logger.level = Logger::DEBUG
            else
                $logger.level = Logger::INFO
            end
        rescue
            abort('Log file not found.  Exiting...')
        end

        $logger.info("Starting up PlexReport")
    end


    # Method for parsing the Plex library for every movie
    def getMovies
    	moviedb = TheMovieDB.new($config)
    	omdb = OMDB.new
	    plex = Plex.new($config)
	    movies = Array.new

	    library = plex.get('/library/sections')
        library['MediaContainer']['Directory'].each do | element |
            if element['type'] == 'movie'
		        library = plex.get("/library/sections/#{element['key']}/all")
        		    
                library['MediaContainer']['Video'].each do | element |
		            movie = self.getMovieInfo(element)
		            if !movie.nil?
		                movies.push(movie)
		            end
		        end
	        end
        end
	    return movies.sort_by { |hsh| hsh[:title] }
    end
  
 
    # For a given movie, pulls it's metadata from the search agent
    # Parameters: 
    #   movie: Plex movie object, from '/library/sections/<movie_library_id/all' 
    def getMovieInfo(plex_movie)
        moviedb = TheMovieDB.new($config)
        omdb = OMDB.new
        plex = Plex.new($config)
        movies = Array.new

        $logger.debug(plex_movie)
        if plex_movie.is_a?(Hash)
        if (Time.now.to_i - plex_movie['addedAt'].to_i < 604800)
            plex_movie = plex.get("/library/metadata/#{plex_movie['ratingKey']}")['MediaContainer']['Video']

            # This is some contrivulted logic to strip off the moviedb.org id
            # from the Plex mediadata.  I wish Plex made this information
            # easier to get
            if plex.get("/library/metadata/#{plex_movie['ratingKey']}")['MediaContainer']['Video']['guid'].include?("themoviedb")
                movie_id = plex.get("/library/metadata/#{plex_movie['ratingKey']}")['MediaContainer']['Video']['guid'].gsub(/com.plexapp.agents.themoviedb:\/\//, '').gsub(/\?lang.*/, '')
            elsif plex.get("/library/metadata/#{plex_movie['ratingKey']}")['MediaContainer']['Video']['guid'].include?("imdb")
                movie_id = plex.get("/library/metadata/#{plex_movie['ratingKey']}")['MediaContainer']['Video']['guid'].gsub(/com.plexapp.agents.imdb:\/\//, '').gsub(/\?lang.*/, '')
                $logger.debug(movie_id)
                return nil
            else
                $logger.error("Movie #{plex_movie['title']} using incompatiable agent")
                return nil
            end

            if !movie_id.include?('local')
                begin
                    movie = moviedb.get("movie/#{movie_id}")
                    omdb_result = omdb.get(movie['imdb_id'])

                    $logger.info("Reporting Movie: #{movie['title']}")
                        return {
                            :id          => movie['id'],
                            :title       => movie['title'],
                            :image       => "https://image.tmdb.org/t/p/w154#{movie['poster_path']}",
                            :date        => omdb_result['Year'],
                            :tagline     => movie['tagline'],
                            :synopsis    => movie['overview'],
                            :runtime     => movie['runtime'],
                            :imdb        => "http://www.imdb.com/title/#{movie['imdb_id']}",
                            :imdb_rating => omdb_result['imdbRating'],
                            :imdb_votes  => omdb_result['imdbVotes'],
                            :director    => omdb_result['Director'],
                            :actors      => omdb_result['Actors'],
                            :genre       => omdb_result['Genre'],
                            :released    => omdb_result['Released'],
                            :rating      => omdb_result['Rated']
                        }
                rescue
                end
            end
        end
        end
    end


    # Method for getting new TV shows from the Plx server  
    def getTVEpisodes
        plex = Plex.new($config)
        tv_episodes = Hash.new
        tv_episodes[:new] = []
        tv_episodes[:seasons] = []

        library = plex.get('/library/sections')
        library['MediaContainer']['Directory'].each do | element |
            if element['type'] == 'show'
                library = plex.get("/library/sections/#{element['key']}/all")
                library['MediaContainer']['Directory'].each do | element |
                    tv_episodes = self.getTVInfo(element, tv_episodes)
                end
            end
        end

        tv_episodes[:new].sort_by! { |hsh| hsh[:series_name] }
        tv_episodes[:seasons].sort_by! { |hsh| hsh[:series_name] }
        return tv_episodes 
    end


    # For a given TV show, determine if thre are new episodes and/or seasons, and adds them approprately
    # Parameters:
    #   tv_show: Plex TV show object from 'library/sections/<tv_show_library_id>/all'
    #   tv_episodes: Array of Hashes of all episodes and seasons
    def getTVInfo(tv_show, tv_episodes)
        thetvdb = TheTVDB.new
        plex = Plex.new($config)

        last_updated = plex.get("/library/metadata/#{tv_show['ratingKey']}")['MediaContainer']['Directory']['updatedAt'].to_i
        if (Time.now.to_i - last_updated < 604800) 
            show_id = plex.get("/library/metadata/#{tv_show['ratingKey']}")['MediaContainer']['Directory']['guid'].gsub(/.*:\/\//, '').gsub(/\?.*/, '')

            begin
                show = thetvdb.get("series/#{show_id}/all/")['Data']
                episodes = show['Episode'].sort_by { |hsh| hsh[:FirstAired] }.reverse!
            rescue
                $logger.error("Connection to thetvdb.com failed while retrieving info for #{tv_show['title']}")
                return tv_episodes
            end

            episodes.each do | episode |
                airdate = nil
                begin
                    airdate_date = Date.parse(episode['FirstAired'])
                rescue
                end

                if !airdate_date.nil?
                    if ((Date.parse(Time.now.to_s) - airdate_date).round < 8 &&
                        (Date.parse(Time.now.to_s) - airdate_date).round > 0)
                        if !tv_episodes[:new].any? {|h| h[:id] == show_id}
                            $logger.info("Reporting #{show['Series']['SeriesName']} Season #{episode['SeasonNumber']} Episode #{episode['EpisodeNumber']}")
                            tv_episodes[:new].push({
                                :id             => show_id,
                                :series_name    => show['Series']['SeriesName'],
                                :image          => "http://thetvdb.com/banners/#{show['Series']['poster']}",
                                :network        => show['Series']['Network'],
                                :imdb           => "http://www.imdb.com/title/#{show['Series']['IMDB_ID']}",
                                :title          => episode['EpisodeName'],
                                :episode_number => "S#{episode['SeasonNumber']} E#{episode['EpisodeNumber']}",
                                :synopsis       => episode['Overview'],
                                :airdate        => episode['FirstAired']
                            })
                        end
                    elsif ((Date.parse(Time.now.to_s) - Date.parse(Time.at(last_updated).to_s)).round < 7)
                        season_mapping = Hash.new
                        dvd_season_mapping = Hash.new
                        show['Episode'].each do | episode_count |
                            season_mapping[episode_count['SeasonNumber']] = episode_count['EpisodeNumber']
                        end
                        show['Episode'].each do | episode_count |
                            if !episode_count['DVD_episodenumber'].nil?
                                dvd_season_mapping[episode_count['SeasonNumber']] = episode_count['DVD_episodenumber'].to_i
                            end
                        end 
                           
                        seasons = plex.get("/library/metadata/#{tv_show['ratingKey']}/children")['MediaContainer']
                            if seasons['Directory'].size > 1
                                seasons = seasons['Directory']
                            end

                            seasons.each do | season |
                                if season.is_a?(Array)
                                    season = seasons
                                end
                                if (Time.now.to_i - season['addedAt'].to_i < 604800)
                                    if (season_mapping[season['index']].to_i == season['leafCount'].to_i ||
                                        dvd_season_mapping[season['index']].to_i == season['leafCount'].to_i )
                                        if tv_episodes[:seasons].detect { |f| f[:id].to_i == show_id.to_i }
                                        tv_episodes[:seasons].each do |x|
                                            if x[:id] == show_id
                                                if !x[:season].include? season['index']
                                                    $logger.info("Reporting #{show['Series']['SeriesName']} Season #{[season['index']]}")
                                                    x[:season].push(season['index'])
                                                end
                                            end
                                        end
                                    else
                                        $logger.info("Reporting #{show['Series']['SeriesName']} Season #{[season['index']]}")
                                        tv_episodes[:seasons].push({
                                            :id             => show_id,
                                            :series_name    => show['Series']['SeriesName'],
                                            :image          => "http://thetvdb.com/banners/#{show['Series']['poster']}",
                                            :season         => [season['index']],
                                            :network        => show['Series']['Network'],
                                            :imdb           => "http://www.imdb.com/title/#{show['Series']['IMDB_ID']}",
                                            :synopsis       => show['Series']['Overview']
                                        })
                                    end
                                end 
                            end
                        end
                    end
                end
            end
        end
    return tv_episodes
    end
end

# Main method that starts the report
def main
    startTime = Time.now
    report = PlexReport.new

    movies = report.getMovies
    new_episodes = report.getTVEpisodes

    new_seasons = new_episodes[:seasons]
    new_episodes = new_episodes[:new]

    YAML.load_file(File.join(File.expand_path(File.dirname(__FILE__)), '../etc/config.yaml') )
    template = ERB.new File.new(File.join(File.expand_path(File.dirname(__FILE__)), "../etc/email_body.erb") ).read, nil, "%"
    mail = MailReport.new($config, $options)

    if (movies.empty? && new_seasons.empty? && new_episodes.empty?)
	    $logger.info('No new media to report!')
	    exit
    end

    mail.sendMail(template.result(binding))

    $logger.info("Script complete.  Ran in #{Time.now - startTime} seconds")
end
main()
