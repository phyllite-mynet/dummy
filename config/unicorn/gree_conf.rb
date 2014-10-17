$unicorn_user = "cyworks"
$unicorn_group = "cyworks"

$dev_processes = 4 # for development
$prod_processes = 16 # for production

# Restart any workers that haven't responded in 30 seconds
$timeout = 30
# ---- end of config ----


# Main Config for Unicorn
rails_env = ENV['RAILS_ENV'] || 'development'
worker_processes (rails_env == 'production' ? $prod_processes : $dev_processes)

# for capistrano
working_directory "/var/www/redm_gree/current"

# Load rails+github.git into the master before forking workers
# for super-fast worker spawn times
preload_app true

timeout $timeout
listen "/tmp/unicorn.sock", :backlog => 2048

stderr_path File.expand_path("log/unicorn-#{rails_env}.stderr.log")
stdout_path File.expand_path("log/unicorn-#{rails_env}.stdout.log")

# For RubyEnterpriseEdition: http://www.rubyenterpriseedition.com/faq.html#adapt_apps_for_cow
if GC.respond_to?(:copy_on_write_friendly=)
  GC.copy_on_write_friendly = true
end

before_fork do |server, worker|
  # the following is highly recomended for Rails + "preload_app true"
  # as there's no need for the master process to hold a connection
  defined?(ActiveRecord::Base) and
    ActiveRecord::Base.connection.disconnect!
  ##
  # When sent a USR2, Unicorn will suffix its pidfile with .oldbin and
  # immediately start loading up a new version of itself (loaded with a new
  # version of our app). When this new Unicorn is completely loaded
  # it will begin spawning workers. The first worker spawned will check to
  # see if an .oldbin pidfile exists. If so, this means we've just booted up
  # a new Unicorn and need to tell the old one that it can now die. To do so
  # we send it a QUIT.
  #
  # Using this method we get 0 downtime deploys.
  old_pid = "#{server.config[:pid]}.oldbin"
  if File.exists?(old_pid) && server.pid != old_pid
    begin
      Process.kill("QUIT", File.read(old_pid).to_i)
    rescue Errno::ENOENT, Errno::ESRCH
      # someone else did our job for us
    end
  end
end

after_fork do |server, worker|
  ##
  # Unicorn master loads the app then forks off workers - because of the way
  # Unix forking works, we need to make sure we aren't using any of the parent's
  # sockets, e.g. db connection

  # the following is *required* for Rails + "preload_app true",
  defined?(ActiveRecord::Base) and
    ActiveRecord::Base.establish_connection

  # CHIMNEY.client.connect_to_server
  # Redis and Memcached would go here but their connections are established
  # on demand, so the master never opens a socket
  GameCache.connection.connection.reset
  DBCache.connection.connection.reset

  ##
  # Unicorn master is started as root, which is fine, but let's
  # drop the workers to git:git

  begin
    uid, gid = Process.euid, Process.egid
    user, group = $unicorn_user, $unicorn_group
    target_uid = Etc.getpwnam(user).uid
    target_gid = Etc.getgrnam(group).gid
    worker.tmp.chown(target_uid, target_gid)
    if uid != target_uid || gid != target_gid
      Process.initgroups(user, target_gid)
      Process::GID.change_privilege(target_gid)
      Process::UID.change_privilege(target_uid)
    end
  rescue => e
    if RAILS_ENV == 'development'
      STDERR.puts "couldn't change user, oh well"
    else
      raise e
    end
  end
end
