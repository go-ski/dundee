# dundee
a set of codes for getting **dee**duplication of photo collections **done**

Has three phases: inventory, analyze, and move

## **inventory**

generates a full list of photo paths, each  with several properties of a photo, such as file size, a couple of different hash numbers (one for pixels and one for metadata), a small grayscale fingerprint grid,  and other photo properties

## **analyze**

works with this list to produce duplicate groups using smart cluster analysis techniques in R, with a Shiny app that provides a visual and data examination of the grouped results along with bulk and individual ways to specify preferred copies

## **move**

moves the preferred and non-preferred copies into separate folders that can later be moved elsewhere or deleted

