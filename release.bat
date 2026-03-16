set date=%date%
echo %date%

git add .
git commit -m "release arg %date%"
git push

git tag -d arg 2>nul
git push origin :refs/tags/arg 2>nul

git tag arg
git push origin arg

gh release delete arg --yes 2>nul
gh release create arg --title "release arg %date%" --notes "release arg %date%"

gh release view arg