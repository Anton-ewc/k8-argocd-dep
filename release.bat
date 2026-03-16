set date=%date%
echo %date%
git add .
git commit -m "release arg $date"
git push
git tag arg
git push origin arg

gh release delete arg --yes
gh release create arg --title "release arg $date" --notes "release arg $date"