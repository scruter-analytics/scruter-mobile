package net.scruter.reactnative;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import org.junit.Test;

public class MarksTest {
  @Test
  public void readsEveryMark() {
    Marks m = Marks.parse("scruter:m;g;i=add_to_cart;f=Delivery%3B%20fast;c=12");
    assertTrue(m.mask);
    assertTrue(m.ignore);
    assertEquals("add_to_cart", m.id);
    assertEquals("Delivery; fast", m.form);
    assertEquals(Integer.valueOf(12), m.index);
  }

  @Test
  public void aPlusIsAPlus() {
    assertEquals("a+b", Marks.parse("scruter:f=a+b").form);
  }

  @Test
  public void survivesWhatItDoesNotKnow() {
    Marks m = Marks.parse("scruter:c=x;z=1;;f=%zz");
    assertFalse(m.mask);
    assertNull(m.index);
    assertEquals("%zz", m.form);
  }
}
