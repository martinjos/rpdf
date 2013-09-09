class PDFDocument
	def initialize(fname)
		@fname = fname
		@fh = nil
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
	def xref
		loc = xref_loc
		if !loc
			return nil
		end
		lines = read_next_lines(loc, 2, 9 + max_offset_digits * 2)
		xinf = []
		if lines =~ /^(xref#{eol})/
			sloc = loc + $1.size
			lines = lines[$1.size..-1]
			while lines =~ /(([0-9]+) ([0-9]+)#{eol})/
				first_id = $2.to_i
				num_ids = $3.to_i
				start = sloc + $1.size
				sloc = start + 20 * num_ids
				xinf << [first_id, num_ids, start]
				lines = read_next_lines(sloc, 1, [9, 3 + max_offset_digits * 2].max)
			end
			if lines =~ /^(trailer#{eol})/
				puts "Found trailer"
				#sloc += $1.size
				#tdict = read_object(sloc)
			end
			xinf
		else
			return nil # can't deal with xref streams for the time being
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
		while data !~ / ^ (#{neol}*#{eol}) {#{n-1}} #{neol}* (#{eol}?$|#{eolp}) $ /x && pos + est < fsize
			est = [est * 2, fsize - pos].min
			data = read_from(pos, est)
		end
		data
	end
	def read_object(pos, est=10)
		data = read_from(pos, est)
		while !((result = parse(data)).is_a? Array) && pos + est < fsize
			est = [est * 2, fsize - pos].min
			data = read_from(pos, est)
		end
		return result
	end
	SeqMap = {'t' => "\t", 'r' => "\r", 'n' => "\n", 'f' => "\f", 'v' => "\v", "\n" => ''}
	def parse(data)
		data = data.sub /^((\s|#{comment})*)/, ''
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
			return [Hash[*rec[0]], ilen + rec[1] + 4]
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
		elsif data =~ /^(<([0-9A-Fa-f\s]*)>)/
			len = $1.size
			str = $2.gsub(/\s+/, '').gsub(/#{hex}{1,2}/) {|match|
				if match.size == 1
					''
				else
					match.hex.chr
				end
			}
			return [str, ilen + len]
		elsif data =~ /^(#{number})/
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
			return [num, ilen + len]
		elsif data =~ /^\/(#{regular}*)/
			len = 1 + $1.size
			if len == data.size
				return ilen # we don't know whether it's the true end
			end
			str = $1
			sym = str.gsub(/#(#{hex}{2})/) {|match|
				$1.hex.chr
			}.to_sym
			return [sym, ilen + len]
		elsif data =~ /^(#{regular}+)/
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
	def regular
		/[^\s()<>\[\]{}\/%]/
	end
	def comment
		/%[^\r\n]*#{eol}/
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
		if str !~ /(#{eol}#{neol}*){3}#{eol}?$/ 
			return nil
		end
		if str =~ /#{eol}startxref#{eol}(#{pos_int})#{eol}%%EOF#{eol}?$/
			return $1.to_i
		else
			return false
		end
	end
end
