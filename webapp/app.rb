require 'sinatra'
require 'csv'
require 'json'

# Configuration
DATA_DIR = ENV['MONITORING_DATA_DIR'] || File.expand_path('../../metrics', __FILE__)

configure do
  set :bind, '0.0.0.0'
  set :port, 4567
end

# Helper to read and parse CSV file
def parse_monitoring_file(filepath)
  data = {
    timestamps: [],
    cpu: { user: [], system: [], idle: [], nice: [] },
    memory: { used: [], free: [], cached: [], total: 0 },
    load: { load1: [], load5: [], load15: [] },
    swap: { used: [], free: [] }
  }

  memory_totals = []

  CSV.foreach(filepath, headers: true) do |row|
    data[:timestamps] << row['timestamp']

    # CPU data
    data[:cpu][:user] << row['cpu_user'].to_f
    data[:cpu][:system] << row['cpu_system'].to_f
    data[:cpu][:idle] << row['cpu_idle'].to_f
    data[:cpu][:nice] << row['cpu_nice'].to_f

    # Memory data (convert to GB for display)
    used_gb = row['memory_used_mb'].to_f / 1024
    free_gb = row['memory_free_mb'].to_f / 1024
    cached_gb = row['memory_cached_mb'].to_f / 1024

    # Calculate total memory (used + free + cached)
    total_gb = used_gb + free_gb + cached_gb
    memory_totals << total_gb

    data[:memory][:used] << used_gb
    data[:memory][:cached] << cached_gb
    data[:memory][:free] << free_gb

    # Load average
    data[:load][:load1] << row['load1'].to_f
    data[:load][:load5] << row['load5'].to_f
    data[:load][:load15] << row['load15'].to_f

    # Swap data (convert to GB for display)
    data[:swap][:used] << (row['swap_used_mb'].to_f / 1024)
    data[:swap][:free] << (row['swap_free_mb'].to_f / 1024)
  end

  # Use the maximum total as the constant total memory
  data[:memory][:total] = memory_totals.max.round(2)

  data
rescue => e
  puts "Error parsing file: #{e.message}"
  nil
end

# List available monitoring files across all vm-name subfolders
get '/api/files' do
  content_type :json

  files = Dir.glob(File.join(DATA_DIR, '**', 'monitoring-*.csv')).map do |filepath|
    relative = filepath.sub("#{DATA_DIR}/", '')
    parts = relative.split('/')
    vm_name = parts.length > 1 ? parts[0] : 'unknown'
    {
      name: File.basename(filepath),
      path: relative,
      vm_name: vm_name,
      size: File.size(filepath),
      modified: File.mtime(filepath).strftime('%Y-%m-%d %H:%M:%S')
    }
  end.sort_by { |f| f[:modified] }.reverse

  files.to_json
end

# Get data for a specific monitoring file (path may include vm_name subfolder)
get '/api/data/*' do
  content_type :json

  relative_path = params['splat'][0]
  filepath = File.join(DATA_DIR, relative_path)

  if File.exist?(filepath) && File.realpath(filepath).start_with?(File.realpath(DATA_DIR))
    data = parse_monitoring_file(filepath)
    if data
      data.to_json
    else
      status 500
      { error: 'Failed to parse file' }.to_json
    end
  else
    status 404
    { error: 'File not found' }.to_json
  end
end

# Main dashboard
get '/' do
  erb :index
end

__END__
