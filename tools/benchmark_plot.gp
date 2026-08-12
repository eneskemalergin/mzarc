if (ARGC != 6) {
    print "usage: gnuplot -c tools/benchmark_plot.gp input.tsv output.svg title x-label highlight-row note"
    exit status 2
}

input_file = ARG1
output_file = ARG2
plot_title = ARG3
x_label = ARG4
highlight_row = ARG5 + 0
figure_note = ARG6

blue = "#0072B2"
orange = "#D55E00"
ink = "#263238"
peer = "#667085"
connector = "#B7C0C8"
grid = "#E3E7EB"
highlight = "#EAF4FB"

set datafile separator "\t"
stats input_file using 5 nooutput
row_count = STATS_records
plot_height = 220 + row_count * 48

set terminal svg size 1440,plot_height dynamic noenhanced font "sans,13" background rgb "white"
set output output_file
set multiplot layout 1,3 rowsfirst title plot_title font ",17"
set label 100 figure_note at screen 0.5,0.935 center front textcolor rgb peer font ",11"

set border 3 back linecolor rgb peer linewidth 1
set grid xtics back linecolor rgb grid
set tics out nomirror textcolor rgb ink
set xrange [0:*]
set yrange [row_count - 0.5:-0.5]
set offsets graph 0.04,0.18,0,0
set tmargin 6

if (highlight_row >= 0) {
    set object 1 rectangle from graph 0, first highlight_row - 0.40 to graph 1, first highlight_row + 0.40 behind fillcolor rgb highlight fillstyle solid 1.0 noborder
}

set lmargin 23
set rmargin 2
set title "A. Artifact size (lower is better)" textcolor rgb ink
set xlabel x_label textcolor rgb ink
unset key
plot input_file using (0):0:5:(0):yticlabels(1) with vectors nohead linewidth 1.5 linecolor rgb connector notitle, \
     input_file using 5:0 with points pointtype 7 pointsize 1.15 linecolor rgb peer notitle, \
     input_file using (highlight_row < 0 || $0 != highlight_row ? $5 : 1/0):0:(sprintf("%.1f%%", $5)) with labels left offset character 0.8,0 textcolor rgb peer notitle, \
     input_file using (highlight_row >= 0 && $0 == highlight_row ? $5 : 1/0):0 with points pointtype 7 pointsize 1.6 linecolor rgb blue notitle, \
     input_file using (highlight_row >= 0 && $0 == highlight_row ? $5 : 1/0):0:(sprintf("%.1f%%", $5)) with labels left offset character 0.8,0 textcolor rgb blue notitle

unset label 100
unset ytics
set lmargin 5
set title "B. Throughput (higher is better)" textcolor rgb ink
set xlabel "MiB/s" textcolor rgb ink
set key at graph 0.5,1.03 center horizontal samplen 1 textcolor rgb ink
plot input_file using 8:($0 + 0.10):($12 - $8):(-0.20) with vectors nohead linewidth 1.2 linecolor rgb connector notitle, \
     input_file using 8:($0 + 0.10) with points pointtype 7 pointsize 1.1 linecolor rgb blue title "Encode", \
     input_file using 12:($0 - 0.10) with points pointtype 5 pointsize 1.1 linecolor rgb orange title "Decode", \
     input_file using (highlight_row >= 0 && $0 == highlight_row ? $8 : 1/0):($0 + 0.10) with points pointtype 7 pointsize 1.55 linecolor rgb blue notitle, \
     input_file using (highlight_row >= 0 && $0 == highlight_row ? $12 : 1/0):($0 - 0.10) with points pointtype 5 pointsize 1.55 linecolor rgb orange notitle, \
     input_file using (highlight_row >= 0 && $0 == highlight_row ? $8 : 1/0):($0 + 0.10):(sprintf("%.0f", $8)) with labels offset character 0,1.1 textcolor rgb blue notitle, \
     input_file using (highlight_row >= 0 && $0 == highlight_row ? $12 : 1/0):($0 - 0.10):(sprintf("%.0f", $12)) with labels offset character 0,-1.1 textcolor rgb orange notitle

set title "C. Peak RSS (lower is better)" textcolor rgb ink
set xlabel "MiB" textcolor rgb ink
plot input_file using 9:($0 + 0.10):($13 - $9):(-0.20) with vectors nohead linewidth 1.2 linecolor rgb connector notitle, \
     input_file using 9:($0 + 0.10) with points pointtype 7 pointsize 1.1 linecolor rgb blue title "Encode", \
     input_file using 13:($0 - 0.10) with points pointtype 5 pointsize 1.1 linecolor rgb orange title "Decode", \
     input_file using (highlight_row >= 0 && $0 == highlight_row ? $9 : 1/0):($0 + 0.10) with points pointtype 7 pointsize 1.55 linecolor rgb blue notitle, \
     input_file using (highlight_row >= 0 && $0 == highlight_row ? $13 : 1/0):($0 - 0.10) with points pointtype 5 pointsize 1.55 linecolor rgb orange notitle, \
     input_file using (highlight_row >= 0 && $0 == highlight_row ? $9 : 1/0):($0 + 0.10):(sprintf("%.1f", $9)) with labels offset character 0,1.1 textcolor rgb blue notitle, \
     input_file using (highlight_row >= 0 && $0 == highlight_row ? $13 : 1/0):($0 - 0.10):(sprintf("%.1f", $13)) with labels offset character 0,-1.1 textcolor rgb orange notitle

unset multiplot
