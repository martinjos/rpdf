require 'set'
require 'zlib'

module PDFUtils
	def self.ensure_array(val)
		if !val.is_a? Array
			val = [val]
		end
		return val
	end
end

class PDFDict < Hash
	def ensure_array(key)
		if has_key?(key)
			PDFUtils.ensure_array(self[key])
		else
			[]
		end
	end
end

class PDFStream
	attr_accessor :dict, :stream
	def initialize(dict, stream)
		@dict = dict
		@stream = stream
	end
	def inspect
		"<PDFStream:#{dict},#{stream.size}>"
	end
	def apply_filters
		filters = dict.ensure_array(:Filter)
		parms = dict.ensure_array(:DecodeParms).map{|x| x.nil? ? {} : x }
		parms += [{}] * (filters.size - parms.size)

		[filters, parms].transpose.each{|filter, parms|
			if filter == :FlateDecode
				allow = Set.new([:Columns, :Predictor])
				parms.keys.each{|name|
					if !allow.member? name
						raise Exception.new("Unrecognised parameter for FlateDecode: #{name}")
					end
				}
				pred = parms[:Predictor]
				cols = parms[:Columns]
				if pred && pred != 12
					raise Exception.new("Unsupported FlateDecode predictor: #{pred}")
				end
				if pred && (!cols || !cols.integer? || cols < 1)
					raise Exception.new("FlateDecode predictor 12 without valid Columns value")
				end
				temp = Zlib::Inflate.inflate(@stream)
				if pred
					temp = diffrows(temp, cols)
				end
				@stream = temp
			else
				raise Exception.new("Unsupported filter: #{filter}")
			end
		}
		dict.delete(:Filter)
		dict.delete(:DecodeParms)
	end
	def diffrows(data, cols)
		divmod = data.size.divmod(cols + 1)
		if divmod[1] != 0
			raise Exception.new("FlateDecoder/PNG predictor: invalid buffer size")
		end
		out = "\0" * (cols * divmod[0])
		out[0...cols] = data[1...cols+1]
		data_i = cols + 2
		out_i = cols
		(1...divmod[0]).each {|i|
			if data[data_i-1].ord != 2
				raise Exception.new("FlateDecoder/PNG predictor - wrong algorithm code - #{data[data_i-1]}")
			end
			(0...cols).each{|j|
				out[out_i] = ((data[data_i].ord + data[data_i-cols-1].ord) % 256).chr
				data_i += 1
				out_i += 1
			}
			data_i += 1
		}
		out
	end
end

class PDFRef
	attr_accessor :doc, :id, :gen
	def initialize(doc, id, gen)
		@doc = doc
		@id = id
		@gen = gen
	end
	def inspect
		"<PDFRef:#{id},#{gen}>"
	end
end

class PDFRefTab
end

class PDFOldRefTab < PDFRefTab
	attr_reader :first, :num
	def initialize(doc, first, num, pos)
		@doc = doc
		@first = first
		@num = num
		@pos = pos
		@data = doc.read_from(pos, 20 * num)
	end
	def load(n)
		if n < first || n >= first + num
			raise Exception.new("Object number out of range")
		end
		pos = (n-@first)*20
		puts "Using pos #{pos}"
		entry = @data[pos...pos+20]
		puts "Entry is #{entry}"
		fpos = entry[0...10].to_i
		gen = entry[11...16].to_i
		new = entry[17] == 'n'
		if !new
			return nil
		end
		puts "Reading object at #{fpos}"
		# FIXME: there is a disconnect between the params passed in here and those used for the cache
		obj = @doc.read_object(fpos)
		return [obj, gen]
	end
	def inspect
		"<PDFOldRefTab:#{@first},#{@num},#{@pos}>"
	end
end

class PDFStreamRefTab < PDFRefTab
	def initialize(stream)
	end
end

class PDFDocument
	def initialize(fname)
		@fname = fname
		@fh = nil
		@xinf = nil
		@trailer = nil
		@cache = Hash.new {|h,k| h[k] = {} }
	end
	def open
		if @fh.nil?
			@fh = File.open(@fname, "rb")
		end
	end
	def close
		@fh.close
		@fh = nil
	end
	def xinf
		ensure_xinf_and_trailer
		@xinf
	end
	def trailer
		ensure_xinf_and_trailer
		@trailer
	end
	def ensure_xinf_and_trailer
		if @xinf.nil? || @trailer.nil?
			load_xinf_and_trailer
		end
	end
	def load_xinf_and_trailer
		loc = xref_loc
		if !loc
			return nil
		end
		lines = read_next_lines(loc, 2, 5)
		@xinf = []
		if lines =~ /\A(xref#{eol})/
			load_real_xinf_and_trailer loc, true
		else
			load_real_xinf_stream loc, true
		end
	end
	def load_real_xinf_and_trailer(loc, latest=false)
		#puts "Loading xinf at #{loc}"
		lines = read_next_lines(loc, 2, 9 + max_offset_digits * 2)
		if lines =~ /\A(xref#{eol})/
			sloc = loc + $1.size
			lines = lines[$1.size..-1]
			while lines =~ /(([0-9]+) ([0-9]+)#{eol})/
				first_id = $2.to_i
				num_ids = $3.to_i
				start = sloc + $1.size
				sloc = start + 20 * num_ids
				@xinf << PDFOldRefTab.new(self, first_id, num_ids, start)
				lines = read_next_lines(sloc, 1, [9, 3 + max_offset_digits * 2].max)
			end
			if lines =~ /\A(trailer#{eol})/
				#puts "Found trailer"
				sloc += $1.size
				trailer = read_object(sloc)
				if latest
					@trailer = trailer
				end
				#p trailer
				if trailer.has_key?(:XRefStm)
					load_real_xinf_stream trailer[:XRefStm]
				end
				if trailer.has_key?(:Prev)
					load_real_xinf_and_trailer trailer[:Prev]
				end
			end
		end
	end
	def load_real_xinf_stream(loc, chain=false)
		xstm = read_object(loc)
		@xinf << xstm
		if @trailer.nil?
			@trailer = xstm.dict
		end
		if chain && xstm.dict.has_key?(:Prev)
			load_real_xinf_stream xstm.dict[:Prev], true
		end
	end
	def xref_loc
		open
		fsize = @fh.size
		bsize = (22 + max_offset_digits)
		loc = xref_loc_for_size(bsize)
		while loc.nil? and bsize < fsize
			bsize = [bsize * 2, fsize].min
			loc = xref_loc_for_size(bsize)
		end
		return loc
	end

#private
	def read_last(n)
		open
		@fh.seek(-n, IO::SEEK_END)
		@fh.read(n)
	end
	def read_from(pos, nbytes)
		open
		@fh.seek(pos)
		@fh.read(nbytes)
	end
	def read_next_lines(pos, n, est)
		open
		data = ""
		fsize = @fh.size
		data = read_from(pos, est)
		while data !~ / \A (#{neol}*#{eol}) {#{n-1}} #{neol}* (#{eol}?\z|#{eolp}) /x && pos + est < fsize
			est = [est * 2, fsize - pos].min
			data = read_from(pos, est)
		end
		data
	end
	def read_object(pos, est=10)
		data = read_from(pos, est)
		fsize = @fh.size
		while !((result = parse(data)).is_a? Array) && pos + est < fsize
			est = [est * 2, fsize - pos].min
			#puts "Retrying with est=#{est}"
			data = read_from(pos, est)
		end
		if result.is_a? Array
			return result[0]
		else
			return nil
		end
	end
	SeqMap = {'t' => "\t", 'r' => "\r", 'n' => "\n", 'f' => "\f", 'v' => "\v", "\n" => ''}
	# TODO: distinguish between can't-succeed and not-enough-data
	def parse(data)
		#puts "Parsing '#{data}'"
		data = data.sub /\A(#{anyspace}*)/, ''
		ilen = $1 ? $1.size : 0
		if data[0] == '['
			rec = parse_array(data[1..-1])
			if rec[1] > data.size - 2 || data[rec[1] + 1] != ']'
				return ilen
			end
			return [rec[0], ilen + rec[1] + 2]
		elsif data[0..1] == '<<'
			rec = parse_array(data[2..-1])
			if rec[1] > data.size - 4 || data[rec[1] + 2..rec[1] + 3] != '>>'
				return ilen
			end
			if rec[0].size % 2 == 1
				rec[0].pop
			end
			return [PDFDict[*rec[0]], ilen + rec[1] + 4]
		elsif data[0] == '('
			str = ''
			pos = 1
			level = 1
			while level > 0 && pos < data.size
				if data[pos] == '\\'
					if pos + 1 == data.size
						return ilen # escape sequence doesn't fit
					end
					if data[pos + 1] == "\r" # \n dealt with via SeqMap
						if pos + 2 < data.size && data[pos + 2] == "\n"
							pos += 1 # 2 more added on at end
						end
						# nothing appended to str
					elsif data[pos + 1] =~ oct
						o = data[pos + 1]
						if pos + 2 < data.size && data[pos + 2] =~ oct
							o += data[pos + 2]
							if pos + 3 < data.size && data[pos + 3] =~ oct
								o += data[pos + 3]
								pos += 1
							end
							pos += 1
						end
						str += o.oct.chr
					elsif SeqMap.has_key? data[pos + 1]
						str += SeqMap[data[pos + 1]]
					else
						str += data[pos + 1]
					end
					pos += 2
				elsif data[pos] == "\r"
					if pos + 1 < data.size && data[pos + 1] == "\n"
						pos += 1
					end
					str += "\n"
					pos += 1
				else
					if data[pos] == '('
						level += 1
					elsif data[pos] == ')'
						level -= 1
						if level == 0
							# skip appending to string
							pos += 1
							break
						end
					end
					str += data[pos]
					pos += 1
				end
			end
			if level > 0
				return ilen
			end
			return [str, ilen + pos]
		elsif data =~ /\A(<([0-9A-Fa-f\s]*)>)/
			len = $1.size
			str = $2.gsub(/\s+/, '').gsub(/#{hex}{1,2}/) {|match|
				if match.size == 1
					''
				else
					match.hex.chr
				end
			}
			return [str, ilen + len]
		elsif data =~ /\A(#{number})/
			len = $1.size
			if len == data.size
				return ilen # we don't know whether it's the true end
			end
			str = $1
			num = nil
			if str =~ /\./
				num = str.to_f
			else
				num = str.to_i
			end
			if num.integer? && num >= 0
				#puts "Got positive integer"
				if data[len..-1] =~ / \A ( #{anyspace}* | #{anyspace}+ #{pos_int} (#{anyspace}* | #{anyspace}+ #{regular}+)) \z /x
					#puts "#{data[len..-1]} - could lead into obj or obj ref"
					return ilen # we don't know whether there is an obj or obj ref
				end
				if data[len..-1] =~ / \A (#{anyspace}+ (#{pos_int}) #{anyspace}+ (R|obj)\b) /x
					#puts "Is obj or obj ref"
					num2 = $2.to_i
					type = $3.to_sym
					xlen = $1.size
					if type == :R
						return [PDFRef.new(self, num, num2), ilen + len + xlen]
					else
						obj = parse(data[len + xlen .. -1])
						if !obj.is_a? Array
							#puts "Failed to parse inner object"
							return ilen # failed to parse object
						end
						token = parse(data[len + xlen + obj[1] .. -1])
						if !token.is_a? Array
							return ilen # failed to get token
						end
						tlen = len + xlen + obj[1] + token[1]
						real_obj = obj[0]
						if obj[0].is_a?(Hash) && token[0] == :stream
							#puts "Parsing stream"
							if data[tlen..-1] !~ /\A ( ( #{comment} | #{sp} )* \r?\n ) /x
								return ilen # failed - stream token followed by inappropriate chars
							end
							#puts "Got good chars"
							tlen += $1.size
							if !obj[0].has_key?(:Length) || !obj[0][:Length].integer? || obj[0][:Length] < 0
								return ilen # failed - not allowing Length refs for now
							end
							length = obj[0][:Length]
							#puts "Got length = #{length}"
							if data.length < tlen + length + 18 # we need at least "\nendstream\nendobj" and 1 more char to ensure end of token
								#puts "Not enough chars"
								return ilen # failed - whole stream not present
							end
							#puts "Got enough chars"
							stream = data[tlen ... tlen + length]
							tlen += length
							estoken = parse(data[tlen .. -1])
							if !estoken.is_a?(Array) || estoken[0] != :endstream
								return ilen
							end
							#puts "Got endstream"
							tlen += estoken[1]
							token = parse(data[tlen .. -1])
							if !token.is_a?(Array)
								return ilen
							end
							#puts "Got final token (hopefully endobj)"
							tlen += token[1]
							real_obj = PDFStream.new(obj[0], stream)
							real_obj.apply_filters # automatically apply filters
						end
						if token[0] != :endobj
							#puts "Failed to get end token (had #{obj[0]}, final parse result is #{token})"
							return ilen # failed to get end token
						end
						@cache[num][num2] = real_obj # automatically store in cache
						return [real_obj, ilen + tlen]
					end
				end
			end
			#puts "Survived"
			return [num, ilen + len]
		elsif data =~ /\A\/(#{regular}*)/
			len = 1 + $1.size
			if len == data.size
				return ilen # we don't know whether it's the true end
			end
			str = $1
			sym = str.gsub(/#(#{hex}{2})/) {|match|
				$1.hex.chr
			}.to_sym
			return [sym, ilen + len]
		elsif data =~ /\A(#{regular}+)/
			len = $1.size
			if len == data.size
				return ilen # we don't know whether it's the true end
			end
			str = $1
			sym = str.to_sym
			if sym == :true
				sym = true
			elsif sym == :false
				sym = false
			elsif sym == :null
				sym = nil
			end
			return [sym, ilen + len]
		end
		return ilen
	end
	def parse_array(data)
		array = []
		pos = 0
		while (item = parse(data[pos..-1])).is_a? Array
			#puts "pos is #{pos}"
			array << item[0]
			pos += item[1]
		end
		pos += item # this will be size of spaces/comments
		return [array, pos]
	end
	def anyspace
		/\s|#{comment}/
	end
	def oct
		/[0-7]/
	end
	def hex
		/[0-9A-F]/i
	end
	def eeol
		/(#{fsp}*(#{comment}|#{eol}))+#{fsp}*/
	end
	def fsp
		/[ \t\f]/
	end
	def sp
		/[ \t]+/
	end
	def number
		/-?([0-9]+(\.[0-9]*)?|\.[0-9]+)/
	end
	def pos_int
		/[0-9]+/
	end
	def regular
		/[^\s()<>\[\]{}\/%]/
	end
	def comment
		/#{bare_comment}#{eol}/
	end
	def bare_comment
		/%[^\r\n]*/
	end
	def max_offset_digits
		1 + Math.log(@fh.size, 10).floor
	end
	def eolp
		/\r\n|\n.|\r[^\n]/
	end
	def eol
		/\n|\r\n?/
	end
	def neol
		/[^\r\n]/
	end
	def pos_int
		/[0-9]+/
	end
	def xref_loc_for_size(bsize)
		str = read_last(bsize)
		#puts "Got #{str.size} bytes"
		if str !~ /(#{eol}#{neol}*){3}#{eol}?\z/ 
			return nil
		end
		if str =~ /#{eol}startxref#{eol}(#{pos_int})#{eol}%%EOF#{eol}?\z/
			return $1.to_i
		else
			return false
		end
	end
end
