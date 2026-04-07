require 'sinatra'
require 'json'
require 'net/http'
require 'openssl'
require 'uri'

SUPABASE_URL        = "https://#{ENV.fetch('SUPABASE_PROJECT_ID')}.supabase.co"
SUPABASE_SECRET_KEY = ENV.fetch('SUPABASE_SECRET_KEY')

configure do
  set :bind, '0.0.0.0'
  set :port, 4567
end

# --- Supabase helpers ---

# Low-level GET — params is an array of pairs to allow duplicate keys
# (e.g. two started_at filters: gte + lte)
def supabase_request(path, pairs = [], extra_headers = {})
  uri = URI("#{SUPABASE_URL}#{path}")
  uri.query = URI.encode_www_form(pairs) unless pairs.empty?
  req = Net::HTTP::Get.new(uri)
  req['apikey']           = SUPABASE_SECRET_KEY
  req['Authorization']    = "Bearer #{SUPABASE_SECRET_KEY}"
  req['Content-Type']     = 'application/json'
  req['Accept-Encoding']  = 'identity'
  extra_headers.each { |k, v| req[k] = v }
  Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_NONE) { |http| http.request(req) }
end

def supabase_get(path, params = {})
  JSON.parse(supabase_request(path, params.to_a).body)
end

def supabase_rpc(fn, params = {})
  uri = URI("#{SUPABASE_URL}/rest/v1/rpc/#{fn}")
  req = Net::HTTP::Post.new(uri)
  req['apikey']          = SUPABASE_SECRET_KEY
  req['Authorization']   = "Bearer #{SUPABASE_SECRET_KEY}"
  req['Content-Type']    = 'application/json'
  req['Accept-Encoding'] = 'identity'
  req.body = params.to_json
  res = Net::HTTP.start(uri.hostname, uri.port, use_ssl: true, verify_mode: OpenSSL::SSL::VERIFY_NONE) { |http| http.request(req) }
  JSON.parse(res.body)
end

# --- VM Metrics API ---

get '/api/vm_filters' do
  content_type :json
  rows = supabase_get('/rest/v1/builds', {
    select: 'workflow_name,branch,repository,runner_os,cpu_count'
  })
  os_cpu_map = rows.each_with_object({}) do |r, h|
    os = r['runner_os']; cpu = r['cpu_count']
    next unless os && cpu
    (h[os] ||= []) << cpu unless h[os]&.include?(cpu)
  end
  os_cpu_map.each_value(&:sort!)
  {
    workflows:        rows.map { |r| r['workflow_name'] }.compact.uniq.sort,
    branches:         rows.map { |r| r['branch'] }.compact.uniq.sort,
    repositories:     rows.map { |r| r['repository'] }.compact.uniq.sort,
    runner_os_values: rows.map { |r| r['runner_os'] }.compact.uniq.sort,
    cpu_counts:       rows.map { |r| r['cpu_count'] }.compact.uniq.sort,
    os_cpu_map:       os_cpu_map
  }.to_json
end

get '/api/vm_runs' do
  content_type :json
  pairs = [
    ['select', 'run_id,vm_name,workflow_name,repository,branch,started_at,build_duration_seconds'],
    ['order',  'started_at.desc'],
    ['limit',  '10']
  ]
  pairs << ['started_at',    "gte.#{params['started_from']}"] unless params['started_from'].to_s.strip.empty?
  pairs << ['started_at',    "lte.#{params['started_to']}"]   unless params['started_to'].to_s.strip.empty?
  pairs << ['workflow_name', "eq.#{params['workflow_name']}"] unless params['workflow_name'].to_s.strip.empty?
  pairs << ['branch',        "eq.#{params['branch']}"]        unless params['branch'].to_s.strip.empty?
  pairs << ['repository',    "eq.#{params['repository']}"]    unless params['repository'].to_s.strip.empty?
  pairs << ['runner_os',     "eq.#{params['runner_os']}"]     unless params['runner_os'].to_s.strip.empty?
  pairs << ['cpu_count',     "eq.#{params['cpu_count']}"]     unless params['cpu_count'].to_s.strip.empty?

  res   = supabase_request('/rest/v1/builds', pairs, 'Prefer' => 'count=exact')
  total = res['content-range']&.split('/')&.last.to_i || 0
  runs  = JSON.parse(res.body)
  { total: total, runs: runs }.to_json
end

get '/api/metrics/:run_id' do
  content_type :json
  run_id = params['run_id']

  metrics_rows = supabase_get('/rest/v1/metrics', {
    select: 'sampled_at,cpu_user,cpu_system,cpu_idle,cpu_nice,' \
            'memory_used_mb,memory_free_mb,memory_cached_mb,' \
            'load1,load5,load15,swap_used_mb,swap_free_mb',
    run_id: "eq.#{run_id}",
    order:  'sampled_at.asc'
  })

  build = supabase_get('/rest/v1/builds', {
    select: 'started_at,build_duration_seconds,cpu_count',
    run_id: "eq.#{run_id}",
    limit:  '1'
  }).first || {}

  memory_totals = metrics_rows.map do |r|
    (r['memory_used_mb'].to_f + r['memory_free_mb'].to_f + r['memory_cached_mb'].to_f) / 1024
  end

  {
    timestamps: metrics_rows.map { |r| r['sampled_at'] },
    cpu: {
      user:   metrics_rows.map { |r| r['cpu_user'].to_f },
      system: metrics_rows.map { |r| r['cpu_system'].to_f },
      idle:   metrics_rows.map { |r| r['cpu_idle'].to_f },
      nice:   metrics_rows.map { |r| r['cpu_nice'].to_f }
    },
    memory: {
      used:   metrics_rows.map { |r| r['memory_used_mb'].to_f / 1024 },
      free:   metrics_rows.map { |r| r['memory_free_mb'].to_f / 1024 },
      cached: metrics_rows.map { |r| r['memory_cached_mb'].to_f / 1024 },
      total:  memory_totals.max&.round(2) || 0
    },
    load: {
      load1:  metrics_rows.map { |r| r['load1'].to_f },
      load5:  metrics_rows.map { |r| r['load5'].to_f },
      load15: metrics_rows.map { |r| r['load15'].to_f }
    },
    swap: {
      used: metrics_rows.map { |r| r['swap_used_mb'].to_f / 1024 },
      free: metrics_rows.map { |r| r['swap_free_mb'].to_f / 1024 }
    },
    job_start:        build['started_at'] || '',
    duration_seconds: build['build_duration_seconds'].to_i,
    cpu_count:        build['cpu_count'].to_i
  }.to_json
end

# --- Builds Dashboard API ---

def builds_rpc_params(p)
  h = {}
  h[:p_weeks]      = p['weeks'].to_i     unless p['weeks'].to_s.strip.empty?
  h[:p_workflow]   = p['workflow']        unless p['workflow'].to_s.strip.empty?
  h[:p_branch]     = p['branch']          unless p['branch'].to_s.strip.empty?
  h[:p_repository] = p['repository']      unless p['repository'].to_s.strip.empty?
  h[:p_runner_os]  = p['runner_os']       unless p['runner_os'].to_s.strip.empty?
  h[:p_cpu_count]  = p['cpu_count'].to_i  unless p['cpu_count'].to_s.strip.empty?
  h[:p_from]       = p['from']            unless p['from'].to_s.strip.empty?
  h[:p_to]         = p['to']              unless p['to'].to_s.strip.empty?
  h
end

get '/api/builds/filters' do
  content_type :json
  rows = supabase_get('/rest/v1/builds', {
    select: 'workflow_name,branch,repository,runner_os,cpu_count'
  })
  os_cpu_map = rows.each_with_object({}) do |r, h|
    os = r['runner_os']; cpu = r['cpu_count']
    next unless os && cpu
    (h[os] ||= []) << cpu unless h[os]&.include?(cpu)
  end
  os_cpu_map.each_value(&:sort!)
  {
    workflows:        rows.map { |r| r['workflow_name'] }.compact.uniq.sort,
    branches:         rows.map { |r| r['branch'] }.compact.uniq.sort,
    repositories:     rows.map { |r| r['repository'] }.compact.uniq.sort,
    runner_os_values: rows.map { |r| r['runner_os'] }.compact.uniq.sort,
    cpu_counts:       rows.map { |r| r['cpu_count'] }.compact.uniq.sort,
    os_cpu_map:       os_cpu_map
  }.to_json
end

JOB_METRICS = %w[failure_rate queue_time_p90 queue_time_p50].freeze

get '/api/builds/stats' do
  content_type :json
  rp          = builds_rpc_params(params)
  build_stats = supabase_rpc('builds_stats', rp)
  build_stats = build_stats.is_a?(Array) ? build_stats.first : build_stats

  job_stats = begin
    r = supabase_rpc('job_stats', rp)
    r.is_a?(Array) ? r.first : r
  rescue StandardError
    {}
  end

  (build_stats || {}).merge(job_stats || {}).to_json
end

get '/api/builds/trend' do
  content_type :json
  metric     = params['metric'] || 'p90'
  fn         = JOB_METRICS.include?(metric) ? 'job_trend' : 'builds_trend'
  rpc_params = builds_rpc_params(params).merge(p_metric: metric)
  supabase_rpc(fn, rpc_params).to_json
end

get '/api/builds/breakdown' do
  content_type :json
  metric     = params['metric']    || 'p90'
  fn         = JOB_METRICS.include?(metric) ? 'job_breakdown' : 'builds_breakdown'
  rpc_params = builds_rpc_params(params).merge(
    p_metric:    metric,
    p_dimension: params['dimension'] || 'workflow'
  )
  rows   = supabase_rpc(fn, rpc_params)
  result = {}
  rows.each do |r|
    dim = r['dim'] || 'unknown'
    result[dim] ||= []
    result[dim] << { week: r['week'], value: r['value'] }
  end
  result.to_json
end

# --- Pages ---

get '/' do
  erb :index
end

get '/builds' do
  erb :builds
end
