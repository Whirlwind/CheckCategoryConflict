#!/usr/bin/env ruby
# encoding: UTF-8

require 'pathname'

FRAMEWORK_SEARCH_PATHS = []
LIBRARY_SEARCH_PATHS = []
FRAMEWORKS = []
LIBRARIES = []

FRAMEWORK_PATHS = []
LIBRARIE_PATHS = []

CATEGORIES = {}

class ConflictItem
	attr_accessor :file_path, :module_name, :func_name, :isSDK, :primary_item
	def initialize(module_name, file_path, func_name)
		@file_path = file_path
		@module_name = module_name.nil? ? File.basename(file_path, '.*').gsub("libPods-", "") : module_name
		@func_name = func_name
		@isSDK = !SDKROOT.nil? && file_path.start_with?(SDKROOT)
	end

  	def ==(another)
  		self.module_name == another.module_name && self.func_name == another.func_name
	end

	def setPrimaryItem(item)
		@primary_item = item
	end

	def description
		if @primary_item.nil?
			@func_name
		else
			"#{@func_name}  >>  与 #{@primary_item.module_name} #{@primary_item.func_name} 冲突"
		end
	end

	def isMainProject?
		@module_name == ENV['PROJECT_NAME']
	end
end

# 获取系统库搜索路径，SDK 由于去除了符号，因此不能直接从 SDK 中获取函数列表
# 从 Device Support 中获取符号化的 SDK
def get_sdk_root
	device_support_path = "#{ENV['HOME']}/Library/Developer/Xcode/iOS DeviceSupport"
	sdk_path = Dir["#{device_support_path}/*"].last
	if sdk_path.nil?
		puts "warning: 符号化 SDK 不存在，将无法分析系统库！"
		return nil
	else
		return sdk_path
	end
end

# 分析环境变量参数
def parse_args(args)
	index = 0
	arg_list = []
	while args && args.length > 0 && args.length > index
		space_index = args.index(" ", index)
		space_index = -1 if space_index.nil?
		arg = args[0..space_index]
		if arg.count("\"") % 2 == 0 && arg.count("'") % 2 == 0
			arg_list << arg.strip
			args = space_index >= 0 ? args[space_index+1..-1] : nil
			index = 0
		end
	end
	arg_list
end

# 分析 Library 搜索路径
def parse_library_search_paths
	parse_args(ENV['LIBRARY_SEARCH_PATHS']).each { |arg| LIBRARY_SEARCH_PATHS << arg.gsub("\"", "") }
	unless SDKROOT.nil?
		# 添加系统库搜索路径
		system_library_search_path = File.join(SDKROOT, "Symbols/usr/lib")
		LIBRARY_SEARCH_PATHS << system_library_search_path unless LIBRARY_SEARCH_PATHS.include?(system_library_search_path)
	end
end

# 分析 Framework 搜索路径
def parse_framework_search_paths
	parse_args(ENV['FRAMEWORK_SEARCH_PATHS']).each { |arg| FRAMEWORK_SEARCH_PATHS << arg.gsub("\"", "") }
	unless SDKROOT.nil?
		# 添加系统库搜索路径
		system_framework_search_path = File.join(SDKROOT, "Symbols/System/Library/Frameworks")
		FRAMEWORK_SEARCH_PATHS << system_framework_search_path unless FRAMEWORK_SEARCH_PATHS.include?(system_framework_search_path)
	end
end

# 分析链接符号
def parse_link_flags
	flags = parse_args(ENV['OTHER_LDFLAGS'])
	while flags.count > 0
		flag = flags.shift
		if flag == "-framework" || flag == '-weak_framework'
			flag = flags.shift
			flag.gsub!("\"", "")
			FRAMEWORKS << flag unless FRAMEWORKS.include?(flag)
		elsif flag.start_with?("-l")
			flag = flag[2..-1].gsub("\"", "")
			LIBRARIES << flag unless LIBRARIES.include?(flag)
		end
	end
end

# 搜索指定文件，获取绝对路径
def search_path(filename, paths)
	paths.each do |path|
		full_path = File.join(path, filename)
		return full_path = Pathname.new(full_path).realpath.to_s if File.file?(full_path)
	end
	nil
end

# 获取 Framework 绝对路径
def search_framework
	FRAMEWORKS.each do |framework|
		path = search_path("#{framework}.framework/#{framework}", FRAMEWORK_SEARCH_PATHS)
		FRAMEWORK_PATHS << path if (!path.nil? && !FRAMEWORK_PATHS.include?(path))
	end
end

# 获取 Library 绝对路径
def search_library
	LIBRARIES.each do |library|
		["a", "dylib"].each do |ext|
			path = search_path("lib#{library}.#{ext}", LIBRARY_SEARCH_PATHS)
			if (!path.nil? && !LIBRARIE_PATHS.include?(path))
				LIBRARIE_PATHS << path
				break
			end
		end
	end
end

def add_item_to_categoryies(func_name, item)
	array = CATEGORIES[func_name]
	if array.nil?
		CATEGORIES[func_name] = [item]
	else 
		unless array.include?(item)
			if item.isSDK
				array.insert(0, item)
			elsif item.isMainProject?
				for i in 0..array.count
					if i == array.count
						array << item
					elsif !array[i].isSDK
						array.insert(i, item)
						break
					end
				end
			else
				array << item
			end
		end
	end
end

# 从二进制中分析 Category 符号
def parse_category(filepath, prefix=nil)
	IO.popen("nm \"#{filepath}\" 2> /dev/null | grep -oh '[-+]\\[.*(.*) .*\\]$' ") do |io|
		io.read.split("\n").each do |line|
			func = line.gsub(/\(.*\)/.match(line)[0], "")
			item = ConflictItem.new(prefix, filepath, line)
			add_item_to_categoryies(func, item)
		end
	end
end

# 从二进制中分析函数列表，只对系统库有效
def parse_method(filepath)
	IO.popen("nm \"#{filepath}\" 2> /dev/null | grep -oh '[-+]\\[.* .*\\]$' ") do |io|
		io.read.split("\n").each do |line|
			item = ConflictItem.new(nil, filepath, line)
			add_item_to_categoryies(line, item)
		end
	end
end

CONFLICT_CATEGORIES = {}
def add_item_to_conflict_categories(item, primary_item)
	item.setPrimaryItem(primary_item)
	array = CONFLICT_CATEGORIES[item.module_name]
	if array.nil?
		CONFLICT_CATEGORIES[item.module_name] = [item.description]
	else 
		array << item.description
	end
end

# 分析出哪些 Category 应该被修复
# 原则上，
#  		1.和系统 SDK 冲突都应当修复
# 		2.和主项目冲突应该被修复
def apply_rule
	CATEGORIES.each do |func, array|
		next if array.count < 2
		primary_module = nil
		array.each do |item|
			if item.isSDK
				primary_module = item
				next
			end
			if primary_module
				add_item_to_conflict_categories(item, primary_module)
				next
			end
				
			if item.isMainProject?
				primary_module = item
			else
				add_item_to_conflict_categories(item, primary_module)
			end
		end
	end
end

SDKROOT = get_sdk_root
parse_library_search_paths
parse_framework_search_paths
parse_link_flags

search_framework
search_library

FRAMEWORK_PATHS.each do |framework|
	parse_category(framework)
	if framework.start_with?(SDKROOT)
		parse_method(framework)
	end
end

LIBRARIE_PATHS.each do |library|
	parse_category(library)
	if library.start_with?(SDKROOT)
		parse_method(library)
	end
end

# 分析主项目中间二进制文件
Dir.glob("#{ENV['OBJECT_FILE_DIR_normal']}/#{ENV['CURRENT_ARCH']}/*.o") do |file|
	parse_category(file, ENV['PROJECT_NAME'])
end

apply_rule

if CONFLICT_CATEGORIES.count > 1
	count = 0

	# 输出文件
	out_path = "#{ENV['OBJECT_FILE_DIR_normal']}/#{ENV['CURRENT_ARCH']}/conflict_categories.txt"
	File.open(out_path, "w:UTF-8") do |f| 
		CONFLICT_CATEGORIES.each do |module_name, array|
			f.write "#{module_name}\n"
			array.each do |item|
				f.write "\t#{item}\n"
			end
			count = count + array.count
		end
	end 

	puts "warning: 发现 #{CONFLICT_CATEGORIES.count} 个库存在 #{count} 个 Category 函数存在同名冲突！详细查看 #{out_path}"
	
end
