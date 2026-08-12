if (ARGC != 4) {
    print "usage: gnuplot -c tools/benchmark_plot.gp input.tsv output.svg title x-label"
    exit status 2
}

input_file = ARG1
output_file = ARG2
plot_title = ARG3
x_label = ARG4

set datafile separator "\t"
stats input_file using 5 nooutput
row_count = STATS_records
plot_height = 170 + row_count * 42

set terminal svg size 1440,plot_height dynamic noenhanced font "sans,11" background rgb "white"
set output output_file
set multiplot layout 1,3 rowsfirst title plot_title font ",14"

set border 3 back linecolor rgb "#888888"
set grid xtics back linecolor rgb "#dddddd"
set tics out nomirror
set xrange [0:*]
set yrange [row_count - 0.5:-0.5]
set offsets graph 0.05,0.10,0,0
set tmargin 5

set lmargin 23
set rmargin 2
set title "Artifact size (lower is better)"
set xlabel x_label
unset key
plot input_file using 5:0:yticlabels(1) with points pointtype 7 pointsize 1.1 linecolor rgb "#444444" notitle

unset ytics
set lmargin 5
set title "Throughput (higher is better)"
set xlabel "MiB/s"
set key at graph 0.5,1.02 center horizontal samplen 1
plot input_file using 8:($0 + 0.10) with points pointtype 7 pointsize 1.1 linecolor rgb "#0072B2" title "Encode", \
     input_file using 12:($0 - 0.10) with points pointtype 5 pointsize 1.1 linecolor rgb "#D55E00" title "Decode"

set title "Peak RSS (lower is better)"
set xlabel "MiB"
plot input_file using 9:($0 + 0.10) with points pointtype 7 pointsize 1.1 linecolor rgb "#0072B2" title "Encode", \
     input_file using 13:($0 - 0.10) with points pointtype 5 pointsize 1.1 linecolor rgb "#D55E00" title "Decode"

unset multiplot
