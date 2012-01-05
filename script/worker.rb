require 'job' 
require 'beanstalk-client'

class Worker < ActiveRecord::Base
  
  MAX_JOB_LIMIT = 500
 
 
  def self.create_fb_albums
    config        = YAML.load_file(Rails.root.join("config/beanstalk.yml"))[Rails.env]
    beanstalk     = Beanstalk::Pool.new([config['host']])
    beanstalk.watch "fbalbums"
    beanstalk.ignore "default"
    job           = Job.new("","","", false)
    
    begin
      while true
          if File.exists?('/tmp/PAUSE_FBALBUM')
            puts "Pause upload file is present. Pausing..."
            sleep 30
            next
          elsif File.exists?('/tmp/STOP_FBALBUM')
            puts "Stop upload file is present. Exiting..."
            break
          end
          beanstalk_job = beanstalk.reserve
          set_id        = (beanstalk_job.body).to_i
          job.create_albums_for_photoset(set_id)      
          beanstalk_job.delete
      end
    rescue Exception => e
      puts "Exception reached => " + e
      puts e.backtrace
    end    
  end
  
  
  def self.upload_loop_batch
    config = YAML.load_file(Rails.root.join("config/beanstalk.yml"))[Rails.env]
    beanstalk = Beanstalk::Pool.new([config['host']])
    begin
      while true
        if File.exists?('/tmp/PAUSE_UPLOAD')
          puts "Pause upload file is present. Pausing..."
          sleep 30
          next
        elsif File.exists?('/tmp/STOP_UPLOAD')
          puts "Stop upload file is present. Exiting..."
          break
        end
        photos = nil
        
        #Get a batch of photos and upload them
        beanstalk_job = beanstalk.reserve
        photo_ids = (JSON.parse beanstalk_job.body)
        beanstalk_job.delete
        
        puts "Uploading  " + photo_ids.inspect
        
        photos = Photo.where("id IN (?) and status=?", photo_ids, Constants::PHOTO_PROCESSING)
        
        if photos.nil? or photos.empty?
          sleep 3
          puts "No photos to upload"
          next
        end
        
        jobs = []

        photos.each do |photo|
          photoset = Photoset.find(photo.photoset_id)
          user     = User.find(photoset.user_id)
          job      = { :photo => photo, :user => user} 
          jobs.push(job)
        end

        job = Job.new("","","",false)
        job.batch_upload(jobs)
      end
    rescue Exception => e
      puts "Exception reached => " + e
      puts e.backtrace
    end
  end
    
  def self.split_sets_loop
    while true
      begin
        if File.exists?('/tmp/STOP_SPLIT')
          puts "Stop upload file is present. Exiting..."
          break
        end
        logger.info("Getting unprocessed photosets")
        set = Photoset.where("status = ?", Constants::PHOTOSET_NOTPROCESSED).first
        if set
          user = User.find(set.user_id)
          if set.source == Constants::SOURCE_FLICKR
            logger.info("Splitting flickr set " + set.photoset + " to photos")
            job = Job.new(user.fb_session, user.flickr_access_token, user.flickr_access_secret, true)
            job.split_flickr_sets(user, set.photoset)
          elsif set.source == Constants::SOURCE_PICASA
            logger.info("Splitting picasa set " + set.photoset + " to photos")
            job = Job.new(user.fb_session,"","", false)
            job.split_picasa_sets(user, set.photoset) 
          end
        else
          sleep 4
        end
      rescue Exception => msg
        logger.error("Exception raised" + msg)
      end
    end
  end
  
  def self.beanstalk_pusher
    config = YAML.load_file(Rails.root.join("config/beanstalk.yml"))[Rails.env]
    
    beanstalk = Beanstalk::Pool.new([config['host']])
    
    while true
      jobs_count = beanstalk.stats['current-jobs-ready']
      
      #Do not push to beanstalk if there are more than 500 entries.
      if jobs_count.to_i > Worker::MAX_JOB_LIMIT
        puts "More than #{Worker::MAX_JOB_LIMIT} jobs (#{jobs_count.to_s}), waiting."
        sleep 5
        next  
      else

        #Pick 100 photos from db and push to beanstalk
        photos = Photo.where("status = ?", Constants::PHOTO_NOTPROCESSED).limit(100)
        if photos.empty?
          sleep 10
        end

        photo_ids = photos.map {|photo| photo.id }

        #Split into batches of 5.
        photo_id_batches = []
        while photo_ids.length > 0
          photo_id_batches.push(photo_ids.shift(5))
        end
        
        #Push them into beanstalk
        photo_id_batches.each do |photo_batch|
          #Change status of each photo to processing.
        puts "Pushing #{photo_batch.inspect} to beanstalk"
        Photo.where('id IN (?)', photo_batch).update_all("status = #{Constants::PHOTO_PROCESSING}")
        beanstalk.put(photo_batch.to_json)
        end
      end
    end
  end
  
  def self.beanstalk_queue_count
    config = YAML.load_file(Rails.root.join("config/beanstalk.yml"))[Rails.env]
    beanstalk = Beanstalk::Pool.new([config['host']])
    puts "Current jobs in queue : " + beanstalk.stats['current-jobs-ready'].to_s
  end
  
  def self.photo_count_cron
    photo_count = Photo.select('count(*) as count').where('status = ?', Constants::PHOTO_PROCESSED).first
    Rails.cache.write('photo_count', photo_count[:count])
  end
 
end
