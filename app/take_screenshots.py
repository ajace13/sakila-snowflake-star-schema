"""Takes the two Dashboard screenshots of the running app: unfiltered, then filtered through the real date widget.
Usage: start the app bound to this machine only,
           streamlit run app/streamlit_app.py --server.headless true --server.address localhost --server.port 8765
       then   ~/venv-streamlit/bin/python app/take_screenshots.py [port]
Streamlit scrolls inside its own container, so the browser window is made tall enough to show the whole page."""
import os
import sys

from playwright.sync_api import sync_playwright

port = sys.argv[1] if len(sys.argv) > 1 else "8765"
here = os.path.dirname(os.path.abspath(__file__))
URL = f"http://localhost:{port}"
START, END = "20050601", "20050715"          # the filtered range: 2005-06-01 to 2005-07-15


def metric(page, i=0):
    return page.locator("[data-testid=stMetricValue]").nth(i).inner_text()


def shoot(page, name):
    page.mouse.wheel(0, -10000)
    page.wait_for_timeout(600)
    page.screenshot(path=os.path.join(here, name))


with sync_playwright() as p:
    browser = p.chromium.launch()
    page = browser.new_page(viewport={"width": 1500, "height": 5600})
    page.goto(URL)
    page.wait_for_selector("text=Revenue by store", timeout=120000)
    page.wait_for_timeout(1500)

    page.locator("summary", has_text="Check:").click()                               # open the Check expander
    page.wait_for_selector("text=All 7 comparisons match for payments dated 2005-05-24 to 2006-02-14", timeout=120000)
    page.wait_for_timeout(1000)
    unfiltered = [metric(page, i) for i in range(4)]
    shoot(page, "docs/images/dashboard_unfiltered.png")
    print("unfiltered KPIs:", unfiltered)

    spans = page.locator("[data-testid=stDateInput] span[aria-label]")              # year / month / day of the start and the end date
    spans.nth(0).click()
    page.keyboard.type(START)
    spans.nth(3).click()
    page.keyboard.type(END)
    page.mouse.click(700, 60)                                                        # click away: the widget commits and the app re-runs
    page.wait_for_selector("text=All 7 comparisons match for payments dated 2005-06-01 to 2005-07-15", timeout=120000)
    page.wait_for_timeout(1000)
    filtered = [metric(page, i) for i in range(4)]
    shoot(page, "docs/images/dashboard_filtered.png")
    print("filtered KPIs:  ", filtered)
    assert all(a != b for a, b in zip(unfiltered, filtered)), "every KPI must change with the filter"
    browser.close()
