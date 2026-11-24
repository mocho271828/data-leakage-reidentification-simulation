# gnuplot -c scripts/plot-multiservice.gp docs/multiservice-bounds.csv docs/multiservice-leak-bounds.csv docs/multiservice-map.png
if (ARGC != 3) { print "Usage: gnuplot -c plot-multiservice.gp full.csv partial.csv output.png"; exit error }
set encoding utf8
set terminal pngcairo size 1950,1440 font "sans,15" noenhanced background rgb "white"
set output ARG3
set datafile separator ","

ks = "1 2 3 5 10 20 50 100 200 500 1000"
cs = "0 10 25 50 100 250 500 1000"
ds = "0 20 9800 10000"
row_names = "0人 20人 9,800人 10,000人"
rates = "100 24 12"
missing_color = "#edf0f2"
below_color = "#55738a"
depends_color = "#e8ad40"
reached_color = "#08765c"
unresolved_color = "#885499"
set palette defined (0 below_color, 1 depends_color, 2 reached_color, 3 unresolved_color)
code(v) = (v eq "below" || v eq "below_for_all") ? 0 : ((v eq "depends" || v eq "crosses") ? 1 : (v eq "reached" ? 2 : 3))
index_of(v, vals) = (sum [i=1:words(vals)] (v == int(word(vals,i)) ? i : 0)) - 1
selected(d) = strcol("profile") eq "equal" && column("d_start") <= d && d <= column("d_end")
set cbrange [0:3]
unset colorbox
unset key
unset border
set xrange [-.5:10.5]
set yrange [-.5:7.5]
set tics scale 0 nomirror textcolor rgb "#334452" font "sans,13"
set xtics ("1" 0, "2" 1, "3" 2, "5" 3, "10" 4, "20" 5, "50" 6, "100" 7, "200" 8, "500" 9, "1000" 10)
set ytics ("0" 0, "10" 1, "25" 2, "50" 3, "100" 4, "250" 5, "500" 6, "1000" 7)
set style fill solid 1.0 noborder
set object 1 rectangle from graph 0,0 to graph 1,1 behind fillcolor rgb missing_color fillstyle solid 1.0 noborder
do for [i=0:10] { set arrow i+1 from first i-.5, graph 0 to first i-.5, graph 1 nohead front lc rgb "white" lw 1.4 }
do for [j=0:7] { set arrow j+12 from graph 0, first j-.5 to graph 1, first j-.5 nohead front lc rgb "white" lw 1.4 }

set multiplot layout 4,3 margins .131,.979,.086,.781 spacing .028,.021
set label 1 "新規10人の全員正答確率が80%に届く条件" at screen .031,.953 front font "sans Bold,30" tc rgb "#172c3b"
set label 2 "新規サービスの登録者10,000人　各過去サービスの登録者1,000人　各社で過去の漏えいが1回" at screen .032,.908 front font "sans,17" tc rgb "#344955"
set label 3 "すべての配置で到達" at screen .033,.862 front offset 1.2,0 point pt 5 ps 2.3 lc rgb reached_color tc rgb "#172c3b"
set label 4 "配置によって到達" at screen .233,.862 front offset 1.2,0 point pt 5 ps 2.3 lc rgb depends_color tc rgb "#172c3b"
set label 5 "すべての配置で未達" at screen .421,.862 front offset 1.2,0 point pt 5 ps 2.3 lc rgb below_color tc rgb "#172c3b"
set label 6 "境界を確定できず" at screen .622,.862 front offset 1.2,0 point pt 5 ps 2.3 lc rgb unresolved_color tc rgb "#172c3b"
set label 7 "成立しない人数条件" at screen .797,.862 front offset 1.2,0 point pt 5 ps 2.3 lc rgb missing_color tc rgb "#172c3b"
set label 8 "過去の2社以上に" at screen .013,.816 front font "sans,12" tc rgb "#334452"
set label 9 "登録した実人数" at screen .013,.797 front font "sans,12" tc rgb "#334452"
set label 10 "各社と新規サービスの共通登録者数（人）" at screen .086,.464 center rotate by 90 front font "sans,16" tc rgb "#172c3b"
set label 11 "過去のサービス数（社）" at screen .552,.027 center front font "sans,17" tc rgb "#172c3b"
do for [r=1:4] {
    set label 11+r word(row_names,r) at screen .042,.702-(r-1)*.179 center front font "sans Bold,16" tc rgb "#172c3b"
}
do for [s=1:3] {
    set label 15+s sprintf("各社の漏えい率　%s%%",word(rates,s)) at screen .263+(s-1)*.292,.803 center front font "sans Bold,18" tc rgb "#172c3b"
}
do for [r=1:4] {
    d = int(word(ds,r))
    do for [s=1:3] {
        q = int(word(rates,s))
        if (r == 4) { set xtics textcolor rgb "#334452" } else { set xtics textcolor rgb "white" }
        if (s == 1) { set ytics textcolor rgb "#334452" } else { set ytics textcolor rgb "white" }
        if (q == 100) {
            plot ARG1 using (selected(d) ? index_of(column("services"),ks) : 1/0):(index_of(column("mean_common"),cs)):(.5):(.5):(code(strcol("outcome"))) with boxxyerror lc palette
        } else {
            plot ARG2 using (selected(d) && column("leak_percent")==q ? index_of(column("services"),ks) : 1/0):(index_of(column("mean_common"),cs)):(.5):(.5):(code(strcol("outcome"))) with boxxyerror lc palette
        }
        if (r == 1 && s == 1) { unset label }
    }
}
unset multiplot
unset output
