# gnuplot -c scripts/plot-boundary.gp confirm-summary.csv 全員正答率.png
if (ARGC != 2) { print "Usage: gnuplot -c plot-boundary.gp input.csv output.png"; exit error }
set encoding utf8
set terminal pngcairo size 1590,680 font "sans,16" noenhanced background rgb "white"
set output ARG2
set datafile separator ","

selected(n) = (column("new_size") == n && column("mask") == 2 && column("trials") == 400 && strcol("service") eq "A")
stats ARG1 using ((selected(1) || selected(10) || selected(100)) ? 100*column("lower95") : 1/0) nooutput
bottom = 10*floor((STATS_min-1)/10)
if (bottom < 0) { bottom = 0 }
set yrange [bottom:102]
set ytics 10 nomirror textcolor rgb "#334155"
set xtics nomirror textcolor rgb "#334155"
set border 3 lc rgb "#9ba7b4"
set grid ytics lc rgb "#e2e8ee" back
set bars 0.65
set style line 1 lc rgb "#0072B2" pt 6 ps 1.45 lw 2
set style line 2 lc rgb "#B74617" pt 5 ps .9 lw 2
set style line 3 lc rgb "#515d6b" dt 2 lw 1.6
set arrow 1 from graph 0, first 80 to graph 1, first 80 nohead ls 3 back

set multiplot layout 1,3 margins .082,.978,.195,.740 spacing .043,.0
set label 1 "メールで新規事故の全員を特定できた割合" at screen .06,.925 front font "sans Bold,27" textcolor rgb "#192a3d"
set label 2 "サービスA　各条件400反復　縦線は点ごとの95% Wilson信頼区間" at screen .06,.851 front textcolor rgb "#394958"
set label 3 "過去にサービスAで発生した事故の件数" at screen .53,.061 center front textcolor rgb "#334155"
set format y "%.0f%%"
set ylabel "全員正答率" offset 0,0
unset key
set label 4 "1件で登録者の12%" at screen .59,.851 left offset 1,0 point ls 1 textcolor rgb "#334155"
set label 5 "24%" at screen .763,.851 left offset 1,0 point ls 2 textcolor rgb "#334155"
set arrow 2 from screen .848,.851 to screen .870,.851 nohead ls 3
set label 6 "80%基準" at screen .879,.851 left textcolor rgb "#334155"

do for [panel=1:3] {
    n = int(word("1 10 100",panel))
    set title sprintf("新規事故　%d人",n) font "sans Bold,19" offset 0,.35
    stats [*:*][*:*] ARG1 using (selected(n) ? column("past_count") : 1/0) nooutput
    left = floor(STATS_min)-1
    right = ceil(STATS_max)+1
    set xrange [left:right]
    tick_interval = right-left > 22 ? 5 : (right-left > 12 ? 2 : 1)
    set xtics tick_interval
    plot for [j=1:2] ARG1 using (selected(n) && column("past_percent") == 12*j ? column("past_count") : 1/0):(100*column("rate")):(100*column("lower95")):(100*column("upper95")) with yerrorbars ls j notitle
    unset label
    unset arrow 2
    unset ylabel
    set format y ""
    unset xrange
}
unset multiplot
unset output
