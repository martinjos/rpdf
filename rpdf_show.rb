require 'gtk2'
require 'matrix'

def rpdf_show(doc, page)
	cont = page[-:Contents][].stream
	res = page[-:Resources]
	box = page[-:MediaBox]

	width = box[2] - box[0]
	height = box[3] - box[1]

	window = Gtk::Window.new
	area = Gtk::DrawingArea.new
	area.set_size_request(width, height)
	white = Gdk::Color.new(0xffff, 0xffff, 0xffff)
	black = Gdk::Color.new(0, 0, 0)

	Gtk::StateType.constants.each{|c|
		area.modify_bg(Gtk::StateType.const_get(c), white)
	}

	syms = doc.parse_contents(cont)
	user_mat = Matrix.I(3)
	line_mat = Matrix.I(3)
	text_mat = Matrix.I(3)
	main_mat = Matrix.I(3)
	stack = []

	area.signal_connect("expose_event") {|area, event|
		win = area.window
		gc = Gdk::GC.new(win)
		gc.background = white
		gc.foreground = black

		show_string = lambda{|x, y, str|
			win = area.window
			layout = Pango::Layout.new(area.pango_context)
			layout.text = str

			#FIXME: get next glyph origin?
			rect = layout.extents[1]
			dx = rect.rbearing - rect.lbearing
			text_mat = Matrix.rows([text_mat.row(0), text_mat.row(1),
						[text_mat[2,0]+dx, *text_mat[2,1..2]]])
			
			win.draw_layout(gc, x, y, layout)
		}

		actions = {
			:cm => lambda {|a,b,c,d,e,f|
				# spec p128 - S8.3.4 Transformation Matrices - note 2
				user_mat = Matrix.rows([[a, b, 0], [c, d, 0], [e, f, 1]]) *
								user_mat
				main_mat = text_mat * user_mat
			},
			:q => lambda {
				stack << user_mat
			},
			:Q => lambda {
				user_mat = stack.pop
				main_mat = text_mat * user_mat
			},
			:BT => lambda {
				text_mat = line_mat = Matrix.I(3)
				main_mat = user_mat
			},
			:Tm => lambda {|a,b,c,d,e,f|
				text_mat = line_mat = Matrix.rows([[a, b, 0], [c, d, 0], [e, f, 1]])
				main_mat = text_mat * user_mat
			},
			:Td => lambda {|x,y|
				text_mat = line_mat = Matrix.rows([line_mat.row(0), line_mat.row(1),
										[line_mat[2,0]+x, line_mat[2,1]+y, 1]])
				main_mat = text_mat * user_mat
			},
			:Tj => lambda {|str|
				show_string.call(main_mat[2,0], height-main_mat[2,1], str)
			},
			:TJ => lambda {|array|
				str = array.map{|item|
					String === item ? item : ""
				}.join('')
				show_string.call(main_mat[2,0], height-main_mat[2,1], str)
			},
		}

		syms.each_with_index{|sym, idx|
			action = actions[sym]
			if action && idx >= action.arity
				action.call(*syms[idx-action.arity...idx])
			end
		}
	}

	window.add(area)
	window.show_all
	Gtk.main
end
