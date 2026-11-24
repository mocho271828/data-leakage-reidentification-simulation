# gnuplot -c scripts/plot-service-size.gp docs/service-size-cycles.csv docs/service-size-boundaries.png
if (ARGC != 2) { print "Usage: gnuplot -c plot-service-size.gp cycles.csv output.png"; exit error }
set encoding utf8
set terminal pngcairo size 1600,760 font "sans,16" noenhanced background rgb "white"
set output ARG2
set datafile separator ","

row(p) = p eq "small" ? 3 : p eq "flat" ? 2 : p eq "large" ? 1 : 0
keep(first) = first eq "A" && row(strcol("profile")) > 0
service_count(rule) = keep(strcol("first_type")) && strcol("rule") eq rule ? column("first_services") : 1/0
stats ARG1 using (keep(strcol("first_type")) ? column("first_services") : 1/0) nooutput
xmax = 100 * ceil((STATS_max + 70) / 100.)

ink = "#183447"
muted = "#456070"
low_leak = "#2d7783"
high_leak = "#986033"
unset key
set border 1 lc rgb "#72828a"
set tics nomirror scale 0 textcolor rgb muted font "sans,15"
set xtics 200
set grid xtics back lw 1 lc rgb "#dfe5e7"
set xrange [0:xmax]
set yrange [.5:3.5]
set style fill solid 1.0 noborder
set lmargin at screen .209
set rmargin at screen .555
set bmargin at screen .22
set tmargin at screen .69
set ytics ("小規模社に多い\n750人 ／ 250人" 3, "均等\n500人 ／ 500人" 2, "大規模社に多い\n250人 ／ 750人" 1) textcolor rgb ink font "sans,17" offset -.6,0

set multiplot
set label 1 "新規10人の全員正答確率が80%に達する最小の社数" at screen .035,.934 tc rgb ink font "sans Bold,28"
set label 2 "登録者750人の小規模社と1,250人の大規模社を、小規模社から交互に追加した場合" at screen .036,.871 tc rgb muted font "sans,18"
set label 3 "新規サービスとの共通人数" at screen .035,.762 tc rgb ink font "sans Bold,15"
set label 4 "小規模社 ／ 大規模社" at screen .035,.719 tc rgb muted font "sans,14"
set label 5 "各社の漏えい率を固定" at screen .209,.773 tc rgb ink font "sans Bold,20"
set label 6 "12%" at screen .213,.721 point pt 5 ps 1.7 lc rgb low_leak offset 1.2,0 tc rgb ink
set label 7 "24%" at screen .318,.721 point pt 5 ps 1.7 lc rgb high_leak offset 1.2,0 tc rgb ink
set label 8 "各社の漏えい人数を固定" at screen .619,.773 tc rgb ink font "sans Bold,20"
set label 9 "120人" at screen .623,.721 point pt 5 ps 1.7 lc rgb low_leak offset 1.2,0 tc rgb ink
set label 10 "240人" at screen .756,.721 point pt 5 ps 1.7 lc rgb high_leak offset 1.2,0 tc rgb ink
set label 11 "80%に達するまでの過去サービス数（社）" at screen .585,.127 center tc rgb ink font "sans,17"
set label 12 "新規登録者1万人を、各社の共通人数に合わせて20群に分け、同じ順で繰り返し割り当てた。各社で漏えいは1回。" at screen .036,.052 tc rgb muted font "sans,14"

do for [panel=1:2] {
    lower = panel == 1 ? "rate12" : "count120"
    higher = panel == 1 ? "rate24" : "count240"
    if (panel == 2) {
        unset label
        unset ytics
        set lmargin at screen .619
        set rmargin at screen .965
    }
    plot for [i=0:1] ARG1 using (service_count(i == 0 ? lower : higher)/2):(row(strcol("profile"))+.14-.28*i):(service_count(i == 0 ? lower : higher)/2):(.105) with boxxyerror lc rgb (i == 0 ? low_leak : high_leak), \
         for [i=0:1] ARG1 using (service_count(i == 0 ? lower : higher)):(row(strcol("profile"))+.14-.28*i):(sprintf("%d",column("first_services"))) with labels left offset .4,0 font "sans Bold,16" tc rgb ink
}
unset multiplot
unset output
