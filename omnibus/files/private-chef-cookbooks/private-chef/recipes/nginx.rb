#
# Author:: Adam Jacob (<adam@opscode.com>)
# Copyright:: Copyright (c) 2011 Opscode, Inc.
#
# All Rights Reserved
#

# Create all nginx dirs
nginx_log_dir = node['private_chef']['nginx']['log_directory']
nginx_dir = node['private_chef']['nginx']['dir']
nginx_ca_dir = File.join(nginx_dir, 'ca')
nginx_cache_dir = File.join(nginx_dir, 'cache')
nginx_cache_tmp_dir = File.join(nginx_dir, 'cache-tmp')
nginx_etc_dir = File.join(nginx_dir, 'etc')
nginx_addon_dir = File.join(nginx_etc_dir, 'addon.d')
nginx_d_dir = File.join(nginx_etc_dir, 'nginx.d')
nginx_scripts_dir = File.join(nginx_etc_dir, 'scripts')
nginx_html_dir = File.join(nginx_dir, 'html')
nginx_tempfile_dir = File.join(nginx_dir, 'tmp')

[
  nginx_log_dir,
  nginx_dir,
  nginx_ca_dir,
  nginx_cache_dir,
  nginx_cache_tmp_dir,
  nginx_etc_dir,
  nginx_addon_dir,
  nginx_d_dir,
  nginx_scripts_dir,
  nginx_html_dir,
  nginx_tempfile_dir
].each do |dir_name|
  directory dir_name do
    owner OmnibusHelper.new(node).ownership['owner']
    group OmnibusHelper.new(node).ownership['group']
    mode node['private_chef']['service_dir_perms']
    recursive true
  end
end

# Create empty error log files
%w(access.log error.log current).each do |logfile|
  file File.join(nginx_log_dir, logfile) do
    owner OmnibusHelper.new(node).ownership['owner']
    group OmnibusHelper.new(node).ownership['group']
    mode '0644'
  end
end

# Generate self-signed SSL certificate
ssl_keyfile = File.join(nginx_ca_dir, "#{node['private_chef']['nginx']['server_name']}.key")
ssl_crtfile = File.join(nginx_ca_dir, "#{node['private_chef']['nginx']['server_name']}.crt")
ssl_dhparam = File.join(nginx_ca_dir, 'dhparams.pem')

openssl_x509 ssl_crtfile do
  common_name node['private_chef']['nginx']['server_name']
  org node['private_chef']['nginx']['ssl_company_name']
  org_unit node['private_chef']['nginx']['ssl_organizational_unit_name']
  country node['private_chef']['nginx']['ssl_country_name']
  key_length node['private_chef']['nginx']['ssl_key_length']
  expire node['private_chef']['nginx']['ssl_duration']
  owner 'root'
  group 'root'
  mode '0644'
end

openssl_dhparam ssl_dhparam do
  key_length node['private_chef']['nginx']['dhparam_key_length']
  generator node['private_chef']['nginx']['dhparam_generator_id']
  owner 'root'
  group 'root'
  mode '0644'
end

# Save node attributes back for use in config template generation
node.default['private_chef']['nginx']['ssl_certificate'] ||= ssl_crtfile
node.default['private_chef']['nginx']['ssl_certificate_key'] ||= ssl_keyfile
node.default['private_chef']['nginx']['ssl_dhparam'] ||= ssl_dhparam

# Create static html directory
remote_directory nginx_html_dir do
  source 'html'
  files_backup false
  files_owner 'root'
  files_group 'root'
  files_mode '0644'
  owner OmnibusHelper.new(node).ownership['owner']
  group OmnibusHelper.new(node).ownership['group']
  mode node['private_chef']['service_dir_perms']
end

# Create nginx config
chef_lb_configs = {
  :chef_https_config => File.join(nginx_etc_dir, 'chef_https_lb.conf'),
  :chef_http_config => File.join(nginx_etc_dir, 'chef_http_lb.conf'),
  :script_path => nginx_scripts_dir
}

nginx_vars = node['private_chef']['nginx'].to_hash
nginx_vars = nginx_vars.merge(:helper => NginxErb.new(node))

# Chef API lb config for HTTPS and HTTP
lbconf = node['private_chef']['lb'].to_hash.merge(nginx_vars).merge(
  :redis_host => node['private_chef']['redis_lb']['vip'],
  :redis_port => node['private_chef']['redis_lb']['port'],
  :omnihelper => OmnibusHelper.new(node)
)

['config.lua',
 'dispatch.lua',
 'resolver.lua',
 'route_checks.lua',
 'routes.lua',
 'dispatch_route.lua'].each do |script|
  template File.join(nginx_scripts_dir, script) do
    source "nginx/scripts/#{script}.erb"
    owner 'root'
    group 'root'
    mode '0644'
    variables lbconf
    # Note that due to JIT compile of lua resources, any
    # changes to them will require a full restart to be picked up.
    # This includes any embedded lua.
    notifies :restart, 'runit_service[nginx]' unless backend_secondary?
  end
end

%w(https http).each do |server_proto|
  config_key = "chef_#{server_proto}_config".to_sym
  lb_config = chef_lb_configs[config_key]

  template lb_config do
    source 'nginx/nginx_chef_api_lb.conf.erb'
    owner 'root'
    group 'root'
    mode '0644'
    variables(lbconf.merge(
      :server_proto => server_proto,
      :script_path => nginx_scripts_dir
      )
    )
    notifies :restart, 'runit_service[nginx]' unless backend_secondary?
  end
end

# top-level and internal load balancer config
nginx_config = File.join(nginx_etc_dir, 'nginx.conf')

template nginx_config do
  source 'nginx/nginx.conf.erb'
  owner 'root'
  group 'root'
  mode '0644'
  variables(lbconf.merge(chef_lb_configs).merge(:temp_dir => nginx_tempfile_dir))
  notifies :restart, 'service[nginx]' unless backend_secondary?
end

# Write out README.md for addons dir
cookbook_file File.join(nginx_addon_dir, 'README.md') do
  source 'nginx/nginx-addons.README.md'
  owner 'root'
  group 'root'
  mode '0644'
end

# Set up runit service for nginx component
component_runit_service 'nginx'

# log rotation
template '/etc/opscode/logrotate.d/nginx' do
  source 'logrotate.erb'
  owner 'root'
  group 'root'
  mode '0644'
  variables(node['private_chef']['nginx'].to_hash.merge(
    'postrotate' => '/opt/opscode/embedded/sbin/nginx -s reopen',
    'owner' => OmnibusHelper.new(node).ownership['owner'],
    'group' => OmnibusHelper.new(node).ownership['group']
  ))
end
