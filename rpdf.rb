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
	def xref_loc
		open
		fsize = @fh.size
		max_digits = 1 + Math.log(fsize, 10).floor
		bsize = (22 + max_digits)
		loc = xref_loc_for_size(bsize)
		while loc.nil? and bsize < fsize
			bsize = (bsize * 2) % fsize
			loc = xref_loc_for_size(bsize)
		end
		return loc
	end

private
	def read_last(n)
		open
		@fh.seek(-n, IO::SEEK_END)
		@fh.read(n)
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
